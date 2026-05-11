#!/bin/bash
#
# Inkternity Server — VPS Startup Script
#
# One-shot bootstrap for a fresh Ubuntu 22.04 VPS. Idempotent: re-running
# is safe; existing state is detected via the marker file at
# /var/lib/inkternity-server/.initialized.
#
# Modeled on hvym_tunnler/scripts/vps_startup.sh.
#
# Usage:
#   curl -O https://raw.githubusercontent.com/<org>/inkternity-server/main/scripts/vps_startup.sh
#   chmod +x vps_startup.sh
#   sudo ./vps_startup.sh
#
# Logs: /var/log/inkternity-startup.log
#

set -uo pipefail

#=============================================================================
# CONFIGURATION — edit before first run
#=============================================================================

# Domains (must already have DNS A records pointing at this VPS)
DOMAIN_SIGNAL="signal.hvym.link"
DOMAIN_TURN="turn.hvym.link"

# Email for Let's Encrypt registration
LETSENCRYPT_EMAIL="support@heavymeta.art"

# Git repo to clone
REPO_URL="https://github.com/inviti8/inkternity-server.git"
REPO_BRANCH="main"

# Linux user that runs the stack
SERVICE_USER="inkternity"

#=============================================================================
# END CONFIGURATION
#=============================================================================

SERVICE_HOME="/home/${SERVICE_USER}"
SERVER_DIR="${SERVICE_HOME}/inkternity-server"
MARKER_DIR="/var/lib/inkternity-server"
MARKER_FILE="${MARKER_DIR}/.initialized"
LOG_FILE="/var/log/inkternity-startup.log"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
exec > >(tee -a "$LOG_FILE") 2>&1

echo ""
echo "============================================================"
echo "Inkternity Server Startup"
echo "Started: $(date)"
echo "============================================================"
echo ""

#-----------------------------------------------------------------------------
# Restart shortcut
#-----------------------------------------------------------------------------
if [[ -f "$MARKER_FILE" ]]; then
    echo "=== RESTART DETECTED ==="
    echo "Marker file: $MARKER_FILE"
    cd "$SERVER_DIR" || exit 1
    docker compose up -d
    echo "Services restarted."
    exit 0
fi

#-----------------------------------------------------------------------------
# Sanity
#-----------------------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: must run as root (use sudo)"
    exit 1
fi

#-----------------------------------------------------------------------------
# OS prep
#-----------------------------------------------------------------------------
echo "=== Updating apt ==="
apt-get update -y
apt-get upgrade -y

echo "=== Installing base packages ==="
apt-get install -y \
    git curl ca-certificates ufw \
    certbot python3-certbot-nginx

#-----------------------------------------------------------------------------
# Docker
#-----------------------------------------------------------------------------
if ! command -v docker >/dev/null; then
    echo "=== Installing Docker ==="
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

#-----------------------------------------------------------------------------
# Service user
#-----------------------------------------------------------------------------
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    echo "=== Creating user ${SERVICE_USER} ==="
    useradd -m -s /bin/bash "$SERVICE_USER"
    usermod -aG docker "$SERVICE_USER"
fi

#-----------------------------------------------------------------------------
# Clone repo
#-----------------------------------------------------------------------------
if [[ ! -d "$SERVER_DIR" ]]; then
    echo "=== Cloning ${REPO_URL} (${REPO_BRANCH}) ==="
    sudo -u "$SERVICE_USER" git clone --branch "$REPO_BRANCH" "$REPO_URL" "$SERVER_DIR"
else
    echo "=== Pulling latest from ${REPO_BRANCH} ==="
    sudo -u "$SERVICE_USER" git -C "$SERVER_DIR" fetch origin
    sudo -u "$SERVICE_USER" git -C "$SERVER_DIR" reset --hard "origin/${REPO_BRANCH}"
fi

#-----------------------------------------------------------------------------
# Generate .env if missing
#-----------------------------------------------------------------------------
ENV_FILE="${SERVER_DIR}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "=== Generating .env ==="
    TURN_SECRET=$(openssl rand -hex 32)
    cat > "$ENV_FILE" <<EOF
DOMAIN_SIGNAL=${DOMAIN_SIGNAL}
DOMAIN_TURN=${DOMAIN_TURN}
TURN_USERNAME=inkternity
TURN_SECRET=${TURN_SECRET}
TURN_REALM=$(echo "$DOMAIN_TURN" | sed 's/^turn\.//')
TURN_MIN_PORT=49152
TURN_MAX_PORT=65535
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}
TLS_ENABLED=false
LOG_LEVEL=INFO
EOF
    chown "$SERVICE_USER:$SERVICE_USER" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    echo "Generated .env (TURN secret: ${TURN_SECRET})"
    echo "Save this secret — it goes into Inkternity's default_p2p.json."
fi

# Source it for the rest of this script
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

#-----------------------------------------------------------------------------
# Substitute domains + secrets into config files
#-----------------------------------------------------------------------------
echo "=== Substituting config templates ==="
sed -i "s/signal\.heavymeta\.art/${DOMAIN_SIGNAL}/g" "${SERVER_DIR}/nginx/nginx.conf"
sed -i "s/__TURN_USERNAME__/${TURN_USERNAME}/g; s/__TURN_SECRET__/${TURN_SECRET}/g; s/__TURN_REALM__/${TURN_REALM}/g" \
    "${SERVER_DIR}/coturn/turnserver.conf"

#-----------------------------------------------------------------------------
# Firewall
#-----------------------------------------------------------------------------
echo "=== Configuring ufw ==="
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp                                   # SSH
ufw allow 80/tcp                                   # HTTP (ACME challenge)
ufw allow 443/tcp                                  # HTTPS (signaling)
ufw allow 3478/tcp                                 # TURN
ufw allow 3478/udp                                 # TURN
ufw allow "${TURN_MIN_PORT}:${TURN_MAX_PORT}/udp"  # TURN media relays
ufw --force enable

#-----------------------------------------------------------------------------
# Let's Encrypt — request certs for both domains via standalone HTTP-01
# (we stop nginx briefly if it was running, run certbot, then start back up)
#-----------------------------------------------------------------------------
echo "=== Requesting Let's Encrypt certs ==="
mkdir -p /var/www/certbot

# Bring down any existing nginx so certbot can bind :80
docker compose -f "${SERVER_DIR}/docker-compose.yml" stop nginx 2>/dev/null || true

certbot certonly --standalone --non-interactive --agree-tos \
    -m "$LETSENCRYPT_EMAIL" \
    -d "$DOMAIN_SIGNAL" \
    -d "$DOMAIN_TURN" \
    || { echo "certbot FAILED — verify DNS A records point at this host"; exit 1; }

#-----------------------------------------------------------------------------
# Cert renewal deploy hook
#-----------------------------------------------------------------------------
# Without this, certbot's auto-renewal silently updates /etc/letsencrypt/
# but the running containers keep serving the old in-memory cert.
# See CERT_RENEWAL.md.
echo "=== Installing renewal deploy hook ==="
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-inkternity.sh <<HOOK
#!/bin/bash
# Inkternity Server — post-renewal hook (Docker mode)
# Reload nginx + coturn containers so they pick up the renewed cert.
cd ${SERVER_DIR} || exit 0
docker compose restart nginx coturn
HOOK
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reload-inkternity.sh

#-----------------------------------------------------------------------------
# Build + start the stack
#-----------------------------------------------------------------------------
echo "=== Building and starting docker compose stack ==="
cd "$SERVER_DIR"
docker compose build
docker compose up -d

#-----------------------------------------------------------------------------
# Marker
#-----------------------------------------------------------------------------
mkdir -p "$MARKER_DIR"
touch "$MARKER_FILE"

echo ""
echo "============================================================"
echo "Inkternity Server is up"
echo "  Signaling: wss://${DOMAIN_SIGNAL}/<globalID>"
echo "  TURN:      ${DOMAIN_TURN}:3478 (user: ${TURN_USERNAME})"
echo ""
echo "Next: paste the TURN secret from ${ENV_FILE} into the"
echo "Inkternity fork's assets/data/config/default_p2p.json."
echo "============================================================"
