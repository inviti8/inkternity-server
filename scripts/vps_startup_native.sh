#!/bin/bash
#
# Inkternity Server — VPS Startup Script (NATIVE / systemd mode)
#
# Alternative to the Docker-based scripts/vps_startup.sh, for VPS hosts that
# already run hvym_tunnler under systemd or where the operator prefers a
# Docker-less stack:
#   - signaling   -> systemd-managed Python venv (inkternity-signaling.service)
#   - coturn      -> Ubuntu apt package + the existing coturn/turnserver.conf
#   - TLS termination -> the host nginx (the same one hvym_tunnler installs)
#
# Co-residence behavior:
#   - Does NOT reset ufw (would wipe hvym's existing rules); adds rules only.
#   - Does NOT bind anything to 127.0.0.1:8000 (hvym's uvicorn owns that);
#     signaling listens on 127.0.0.1:8002 / :8003.
#   - Detects whether hvym_tunnler is already installed and issues certs via
#     webroot through its existing /var/www/acme. Falls back to certbot
#     --standalone when running on a host that hasn't seen hvym_tunnler.
#
# Idempotent. Re-runs are safe; a marker at /var/lib/inkternity-server/.initialized
# short-circuits to "ensure services are running".
#
# Usage:
#   sudo ./scripts/vps_startup_native.sh
#
# Logs: /var/log/inkternity-startup.log

set -uo pipefail

#=============================================================================
# CONFIGURATION — edit before first run
#=============================================================================

DOMAIN_SIGNAL="signal.hvym.link"
DOMAIN_TURN="turn.hvym.link"

LETSENCRYPT_EMAIL="support@heavymeta.art"

REPO_URL="https://github.com/inviti8/inkternity-server.git"
REPO_BRANCH="main"

SERVICE_USER="inkternity"

# ACME webroot — shared with hvym_tunnler if present; created here otherwise.
ACME_WEBROOT="/var/www/acme"

#=============================================================================
# END CONFIGURATION
#=============================================================================

SERVICE_HOME="/home/${SERVICE_USER}"
SERVER_DIR="${SERVICE_HOME}/inkternity-server"
VENV_DIR="${SERVER_DIR}/venv"
MARKER_DIR="/var/lib/inkternity-server"
MARKER_FILE="${MARKER_DIR}/.initialized"
LOG_FILE="/var/log/inkternity-startup.log"

NGINX_CONF_SRC="${SERVER_DIR}/nginx/inkternity-signaling.conf"
NGINX_CONF_DST="/etc/nginx/sites-available/inkternity-signaling"
NGINX_CONF_LINK="/etc/nginx/sites-enabled/inkternity-signaling"

SYSTEMD_UNIT_SRC="${SERVER_DIR}/systemd/inkternity-signaling.service"
SYSTEMD_UNIT_DST="/etc/systemd/system/inkternity-signaling.service"

TURNSERVER_CONF_SRC="${SERVER_DIR}/coturn/turnserver.conf"
TURNSERVER_CONF_DST="/etc/turnserver.conf"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
exec > >(tee -a "$LOG_FILE") 2>&1

echo ""
echo "============================================================"
echo "Inkternity Server Native Startup"
echo "Started: $(date)"
echo "============================================================"
echo ""

#-----------------------------------------------------------------------------
# Restart shortcut
#-----------------------------------------------------------------------------
if [[ -f "$MARKER_FILE" ]]; then
    echo "=== RESTART DETECTED ==="
    echo "Marker file: $MARKER_FILE"
    echo "Ensuring services are running…"
    systemctl is-active --quiet nginx                 || systemctl start nginx
    systemctl is-active --quiet coturn                || systemctl start coturn
    systemctl is-active --quiet inkternity-signaling  || systemctl start inkternity-signaling
    echo "Done."
    exit 0
fi

#-----------------------------------------------------------------------------
# Sanity
#-----------------------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: must run as root (use sudo)"
    exit 1
fi

# Detect whether hvym_tunnler is already installed. Drives the cert issuance
# path (webroot vs standalone) and informs whether to install nginx.
HVYM_PRESENT=0
if [[ -f /etc/nginx/sites-enabled/hvym-tunnler ]] || \
   [[ -f /etc/nginx/sites-available/hvym-tunnler ]]; then
    HVYM_PRESENT=1
    echo "Detected co-resident hvym_tunnler — using shared $ACME_WEBROOT for ACME."
else
    echo "No hvym_tunnler nginx config found — will run in standalone mode."
fi

#-----------------------------------------------------------------------------
# apt
#-----------------------------------------------------------------------------
echo "=== apt update / install ==="
apt-get update -y
apt-get install -y \
    git curl ca-certificates \
    python3 python3-venv python3-pip \
    nginx \
    coturn \
    certbot \
    ufw \
    openssl

#-----------------------------------------------------------------------------
# Service user
#-----------------------------------------------------------------------------
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    echo "=== Creating user ${SERVICE_USER} ==="
    useradd -m -s /bin/bash "$SERVICE_USER"
fi

#-----------------------------------------------------------------------------
# Clone / refresh repo
#-----------------------------------------------------------------------------
if [[ ! -d "$SERVER_DIR" ]]; then
    echo "=== Cloning ${REPO_URL} (${REPO_BRANCH}) ==="
    sudo -u "$SERVICE_USER" git clone --branch "$REPO_BRANCH" "$REPO_URL" "$SERVER_DIR"
else
    echo "=== Refreshing repo from ${REPO_BRANCH} ==="
    sudo -u "$SERVICE_USER" git -C "$SERVER_DIR" fetch origin
    sudo -u "$SERVICE_USER" git -C "$SERVER_DIR" reset --hard "origin/${REPO_BRANCH}"
fi

#-----------------------------------------------------------------------------
# .env generation (preserves existing keys on re-run)
#-----------------------------------------------------------------------------
ENV_FILE="${SERVER_DIR}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "=== Generating .env ==="
    TURN_SECRET=$(openssl rand -hex 32)
    cat > "$ENV_FILE" <<EOF
# Inkternity Server runtime config.
# Sourced by inkternity-signaling.service and consumed by this script for
# template substitution. Treat the TURN_SECRET as credential material.

DOMAIN_SIGNAL=${DOMAIN_SIGNAL}
DOMAIN_TURN=${DOMAIN_TURN}
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}

# TURN long-term static credentials (rotate via scripts/rotate_turn_secret.sh).
TURN_USERNAME=inkternity
TURN_SECRET=${TURN_SECRET}
TURN_REALM=$(echo "$DOMAIN_TURN" | sed 's/^turn\.//')
TURN_MIN_PORT=49152
TURN_MAX_PORT=65535

LOG_LEVEL=INFO

# signaling/server.py listener — loopback only; host nginx is the sole
# public entry point. Ports avoid collision with hvym_tunnler's 127.0.0.1:8000.
LISTEN_HOST=127.0.0.1
LISTEN_PORT=8002
EOF
    chown "$SERVICE_USER:$SERVICE_USER" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    echo "Generated .env (TURN secret: ${TURN_SECRET})"
    echo "** SAVE THE TURN SECRET ** — it goes into Inkternity's default_p2p.json."
fi

# Source for the rest of this script
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

#-----------------------------------------------------------------------------
# Python venv + signaling deps
#-----------------------------------------------------------------------------
echo "=== Python venv ==="
if [[ ! -f "${VENV_DIR}/bin/python" ]]; then
    sudo -u "$SERVICE_USER" python3 -m venv "$VENV_DIR"
fi
sudo -u "$SERVICE_USER" "${VENV_DIR}/bin/pip" install --upgrade pip
sudo -u "$SERVICE_USER" "${VENV_DIR}/bin/pip" install \
    -r "${SERVER_DIR}/signaling/requirements.txt"

#-----------------------------------------------------------------------------
# ACME webroot
#-----------------------------------------------------------------------------
mkdir -p "$ACME_WEBROOT"

#-----------------------------------------------------------------------------
# Cert issuance
#-----------------------------------------------------------------------------
# Webroot through the existing nginx :80 when hvym_tunnler is present;
# standalone (briefly stop nginx) otherwise.
if [[ ! -d "/etc/letsencrypt/live/${DOMAIN_SIGNAL}" ]]; then
    echo "=== Requesting Let's Encrypt certs ==="
    if [[ "$HVYM_PRESENT" -eq 1 ]]; then
        certbot certonly --webroot -w "$ACME_WEBROOT" \
            --non-interactive --agree-tos \
            -m "$LETSENCRYPT_EMAIL" \
            -d "$DOMAIN_SIGNAL" \
            -d "$DOMAIN_TURN" \
            || { echo "certbot FAILED — verify DNS A records + that hvym's nginx is serving $ACME_WEBROOT"; exit 1; }
    else
        # Standalone — temporarily free :80. Stops both nginx and any leftover
        # default site. Restored implicitly when we reload nginx below.
        systemctl stop nginx 2>/dev/null || true
        certbot certonly --standalone \
            --non-interactive --agree-tos \
            -m "$LETSENCRYPT_EMAIL" \
            -d "$DOMAIN_SIGNAL" \
            -d "$DOMAIN_TURN" \
            || { echo "certbot FAILED — verify DNS A records point at this host"; exit 1; }
    fi
else
    echo "=== Cert for ${DOMAIN_SIGNAL} already present, skipping certbot ==="
fi

#-----------------------------------------------------------------------------
# Install nginx site (substitute domain into the template at write time;
# leaves the repo file pristine for future git pulls)
#-----------------------------------------------------------------------------
echo "=== Installing nginx site ==="
sed "s/signal\.heavymeta\.art/${DOMAIN_SIGNAL}/g" "$NGINX_CONF_SRC" > "$NGINX_CONF_DST"
ln -sf "$NGINX_CONF_DST" "$NGINX_CONF_LINK"

# In standalone mode, also drop Ubuntu's default site so it doesn't conflict
# on default_server. (Co-resident: leave hvym's sites-enabled alone.)
if [[ "$HVYM_PRESENT" -eq 0 ]] && [[ -L /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
fi

nginx -t
systemctl enable nginx
systemctl reload nginx 2>/dev/null || systemctl start nginx

#-----------------------------------------------------------------------------
# coturn config + enable
#-----------------------------------------------------------------------------
echo "=== Installing coturn config ==="
sed -e "s/__TURN_USERNAME__/${TURN_USERNAME}/g" \
    -e "s/__TURN_SECRET__/${TURN_SECRET}/g" \
    -e "s/__TURN_REALM__/${TURN_REALM}/g" \
    "$TURNSERVER_CONF_SRC" > "$TURNSERVER_CONF_DST"
chmod 644 "$TURNSERVER_CONF_DST"

# Ubuntu's coturn package ships with TURNSERVER_ENABLED=0 to prevent
# accidental boot before configuration; flip it.
if grep -q "^#\?TURNSERVER_ENABLED=" /etc/default/coturn 2>/dev/null; then
    sed -i 's/^#\?TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn
else
    echo "TURNSERVER_ENABLED=1" >> /etc/default/coturn
fi

systemctl enable coturn
systemctl restart coturn

#-----------------------------------------------------------------------------
# Install + start signaling systemd unit
#-----------------------------------------------------------------------------
echo "=== Installing inkternity-signaling.service ==="
cp "$SYSTEMD_UNIT_SRC" "$SYSTEMD_UNIT_DST"
systemctl daemon-reload
systemctl enable inkternity-signaling
systemctl restart inkternity-signaling

#-----------------------------------------------------------------------------
# Cert renewal deploy hook
#-----------------------------------------------------------------------------
# Without this, certbot's auto-renewal silently updates /etc/letsencrypt/
# but nginx + coturn keep serving the old in-memory cert. See CERT_RENEWAL.md.
echo "=== Installing renewal deploy hook ==="
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-inkternity.sh <<'HOOK'
#!/bin/bash
# Inkternity Server — post-renewal hook
# Reload host nginx + restart coturn so they pick up the renewed cert.
systemctl reload nginx   || true
systemctl restart coturn || true
HOOK
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reload-inkternity.sh

#-----------------------------------------------------------------------------
# Firewall — additive, never reset
#-----------------------------------------------------------------------------
echo "=== Firewall (additive) ==="
ufw allow 3478/tcp comment "TURN/STUN TCP"            || true
ufw allow 3478/udp comment "TURN/STUN UDP"            || true
ufw allow "${TURN_MIN_PORT}:${TURN_MAX_PORT}/udp" comment "TURN media relays" || true

if ! ufw status 2>/dev/null | grep -q "^Status: active"; then
    # Standalone mode: ufw not yet enabled. Add baseline rules + enable.
    # (Co-resident: hvym already enabled it with 22/80/443.)
    ufw allow 22/tcp  comment "SSH"   || true
    ufw allow 80/tcp  comment "HTTP"  || true
    ufw allow 443/tcp comment "HTTPS" || true
    ufw --force enable
fi
ufw status verbose 2>/dev/null || true

#-----------------------------------------------------------------------------
# Marker
#-----------------------------------------------------------------------------
mkdir -p "$MARKER_DIR"
cat > "$MARKER_FILE" <<EOF
{
    "initialized_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "domain_signal": "${DOMAIN_SIGNAL}",
    "domain_turn":   "${DOMAIN_TURN}",
    "mode": "native",
    "co_resident_with_hvym": ${HVYM_PRESENT},
    "version": "1.0.0"
}
EOF

#-----------------------------------------------------------------------------
# Summary
#-----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "Inkternity Server is up (native mode)"
echo "  Signaling: wss://${DOMAIN_SIGNAL}/<globalID>"
echo "  Health:    https://${DOMAIN_SIGNAL}/health"
echo "  TURN:      ${DOMAIN_TURN}:3478 (user: ${TURN_USERNAME})"
echo ""
echo "Service status:"
systemctl is-active --quiet inkternity-signaling && echo "  inkternity-signaling: RUNNING" || echo "  inkternity-signaling: FAILED"
systemctl is-active --quiet coturn               && echo "  coturn:               RUNNING" || echo "  coturn:               FAILED"
systemctl is-active --quiet nginx                && echo "  nginx:                RUNNING" || echo "  nginx:                FAILED"
echo ""
echo "Logs:"
echo "  Startup:   $LOG_FILE"
echo "  Signaling: journalctl -u inkternity-signaling -f"
echo "  TURN:      journalctl -u coturn -f"
echo ""
echo "TURN credentials (paste into Inkternity's default_p2p.json):"
echo "  username: ${TURN_USERNAME}"
echo "  secret:   ${TURN_SECRET}"
echo ""
echo "Completed: $(date)"
echo "============================================================"
