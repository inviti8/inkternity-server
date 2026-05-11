# Inkternity Server — Deployment Guide

How to stand up the signaling + TURN stack on a real VPS. For the
"what's actually on disk" conceptual model, read `ARCHITECTURE.md`
first. For local-development walkthroughs (no VPS, no TLS), read
`SETUP.md`.

There are two operationally distinct deployment shapes:

- **Docker mode** (`scripts/vps_startup.sh`) — `docker-compose` stack:
  signaling + nginx + coturn as containers. Use this when the VPS is
  dedicated to Inkternity (nothing else owns :80/:443 on the host).
- **Native mode** (`scripts/vps_startup_native.sh`) — systemd-managed
  signaling on a Python venv, apt-installed coturn, host nginx as the
  TLS terminator. Use this when the VPS already runs hvym_tunnler (or
  any other nginx-fronted service) and you want both stacks to coexist.

Both modes produce identical externals; pick based on what else is
already on the host.

---

## Pre-deployment checklist

| Item | Requirement | Notes |
|---|---|---|
| VPS | Ubuntu 22.04, ≥ 1 vCPU / 1 GiB RAM / 25 GiB SSD | $5–10/mo class works. Tested target. |
| Public IPv4 | Yes | IPv6 is fine to add but not required for either deploy path. |
| DNS A records | `signal.heavymeta.art` → VPS IP; `turn.heavymeta.art` → VPS IP | Must propagate **before** running the bootstrap (HTTP-01 challenge fails otherwise). |
| Email | One mailbox for Let's Encrypt registration | Used for expiry notifications. |
| Root SSH | `sudo` access to the host | Bootstrap scripts must run as root. |
| Existing services | Note whether hvym_tunnler is already deployed | Drives the mode selection. Native co-resides; Docker does not. |
| Pinned-LF dotfiles | `.gitattributes` already pins LF on shell/yaml | If you cloned on Windows, double-check `scripts/*.sh` line endings before running on Linux. |

### Picking a mode

```
Is anything else currently bound to :80 or :443 on this VPS?
├── No  → Docker mode (simplest; one compose stack manages everything)
└── Yes → Native mode (shares the existing nginx; never resets ufw)
```

If you're unsure: `ss -tlnp | grep -E ':80|:443'`. If nothing comes
back, you're free to use either mode. If nginx is listening, use native.

---

## Docker mode

### 1. Edit the bootstrap

```bash
nano scripts/vps_startup.sh
```

Set the four CONFIG variables at the top:

```bash
DOMAIN_SIGNAL="signal.heavymeta.art"
DOMAIN_TURN="turn.heavymeta.art"
LETSENCRYPT_EMAIL="ops@heavymeta.art"
REPO_URL="https://github.com/inviti8/inkternity-server.git"
```

### 2. Run it

```bash
sudo ./scripts/vps_startup.sh
```

Takes ~5–10 minutes on a fresh VPS. Steps performed:

1. `apt update && apt upgrade`.
2. Install Docker CE + the compose plugin.
3. Install certbot, ufw, git.
4. Create unprivileged `inkternity` user, add to `docker` group.
5. Clone this repo to `/home/inkternity/inkternity-server`.
6. Generate `.env` with a fresh 256-bit TURN secret (`openssl rand -hex 32`).
7. Substitute the configured domain into `nginx/nginx.conf` and the TURN
   credentials into `coturn/turnserver.conf`.
8. ufw: allow 22, 80, 443, 3478 (TCP+UDP), 49152–65535/udp.
9. `certbot certonly --standalone` issues certs for `$DOMAIN_SIGNAL`
   and `$DOMAIN_TURN`.
10. `docker compose build` + `docker compose up -d`.
11. Drop a marker at `/var/lib/inkternity-server/.initialized` so reruns
    are idempotent (`up -d` only on rerun).

When it finishes, the script prints the TURN secret and the WSS URL.
**Save the TURN secret** — it must go into Inkternity's
`assets/data/config/default_p2p.json` (see "Pointing Inkternity at the
new infrastructure" below).

### 3. Verify

```bash
docker compose ps
# Expect three services: signaling, nginx, coturn — all Up.

curl https://signal.heavymeta.art/health
# Expect: ok
```

### 4. Operations

```bash
# Service status
docker compose ps

# Tail signaling logs
docker compose logs -f signaling

# Tail coturn logs
docker compose logs -f coturn

# Restart after editing nginx.conf or turnserver.conf
docker compose restart

# Rotate the TURN secret (forces all Inkternity clients to be re-shipped)
sudo ./scripts/rotate_turn_secret.sh
```

---

## Native mode

For VPSes that already run hvym_tunnler (or any other service that owns
:80 / :443), or for operators who prefer systemd over Docker.

### Preconditions specific to co-residence

- hvym_tunnler is installed and its nginx is running on :80/:443. The
  bootstrap auto-detects this via `/etc/nginx/sites-{available,enabled}/hvym-tunnler`
  and switches its certbot strategy to webroot through hvym's existing
  `/var/www/acme`. If hvym is absent, the script falls back to standalone
  mode (briefly stops nginx during cert issuance).
- Port `127.0.0.1:8000` is owned by hvym's uvicorn — do not bind
  anything else there. Native-mode signaling uses `127.0.0.1:8002` and
  `127.0.0.1:8003` to dodge this. These are not configurable from the
  CLI; they're set in the generated `.env` and read by `signaling/server.py`
  via `LISTEN_HOST` / `LISTEN_PORT`.

### 1. Edit the bootstrap

```bash
nano scripts/vps_startup_native.sh
```

Same four config vars as Docker mode, plus optionally:

```bash
ACME_WEBROOT="/var/www/acme"     # shared with hvym; auto-created if missing
SERVICE_USER="inkternity"        # the daemon's Linux user
```

### 2. Run it

```bash
chmod +x scripts/vps_startup_native.sh
sudo ./scripts/vps_startup_native.sh
```

Takes ~5 minutes. Steps performed:

1. Detect hvym_tunnler presence (drives cert strategy + ufw behavior).
2. `apt install`: python3 + venv, nginx (no-op if hvym already installed
   it), coturn, certbot, ufw, git.
3. Create unprivileged `inkternity` user.
4. Clone repo to `/home/inkternity/inkternity-server`.
5. Generate `.env` if absent — includes `LISTEN_HOST=127.0.0.1`,
   `LISTEN_PORT=8002`, `LOG_LEVEL=INFO`, the TURN secret, and domain config.
6. Create the venv and `pip install -r signaling/requirements.txt`.
7. **Issue certs.**
   - Co-resident with hvym: `certbot certonly --webroot -w /var/www/acme`.
   - Standalone: stop nginx, `certbot certonly --standalone`, restart nginx.
8. Substitute the domain into a `/etc/nginx/sites-available/inkternity-signaling`
   copy (not in-place on the repo source), symlink into `sites-enabled/`,
   `nginx -t && systemctl reload nginx`.
9. Substitute TURN credentials into `/etc/turnserver.conf` (not in-place
   on repo), flip `TURNSERVER_ENABLED=1` in `/etc/default/coturn`,
   `systemctl enable --now coturn`.
10. Copy `systemd/inkternity-signaling.service` to `/etc/systemd/system/`,
    `daemon-reload`, `enable --now inkternity-signaling`.
11. **ufw additively** (never resets): add 3478 (TCP+UDP) and
    49152–65535/udp. If ufw is not yet enabled (standalone first-time),
    also add 22/80/443 and enable.
12. Drop a marker at `/var/lib/inkternity-server/.initialized` recording
    `co_resident_with_hvym: 0|1` and timestamp.

### 3. Verify

```bash
# Service status
systemctl is-active inkternity-signaling && echo "signaling: OK" || echo "signaling: FAILED"
systemctl is-active coturn               && echo "coturn:    OK" || echo "coturn:    FAILED"
systemctl is-active nginx                && echo "nginx:     OK" || echo "nginx:     FAILED"

# Health endpoint
curl https://signal.heavymeta.art/health
# Expect: ok

# WS handshake (optional — needs websocat)
websocat wss://signal.heavymeta.art/test
# Expect: connection opens, server logs: "connected id=test (active=1)"
```

### 4. Operations

```bash
# Tail signaling logs
journalctl -u inkternity-signaling -f

# Tail coturn logs
journalctl -u coturn -f

# Restart signaling (e.g., after editing .env)
sudo systemctl restart inkternity-signaling

# Reload nginx (after editing /etc/nginx/sites-available/inkternity-signaling)
sudo nginx -t && sudo systemctl reload nginx

# Rotate the TURN secret
sudo ./scripts/rotate_turn_secret.sh
sudo systemctl restart coturn
```

---

## Pointing Inkternity at the new infrastructure

Edit `assets/data/config/default_p2p.json` in the Inkternity (infinipaint
fork) tree — or, for already-installed users, the deployed config under
their app data directory (e.g. `~/.var/app/com.inkternity.inkternity/config/`
on Linux Flatpak; `$APPDATA/ErrorAtLine0/infinipaint/` on Windows):

```json
{
    "signalingServer": "wss://signal.heavymeta.art",
    "stunList": [
        "stun.l.google.com:19302",
        "stun1.l.google.com:19302",
        "stun2.l.google.com:19302",
        "stun3.l.google.com:19302",
        "stun4.l.google.com:19302"
    ],
    "turnList": [
        {
            "url": "turn.heavymeta.art",
            "port": 3478,
            "username": "inkternity",
            "credential": "<TURN_SECRET from .env>"
        }
    ]
}
```

Rebuild + ship the Inkternity binary; new sessions will route entirely
through HEAVYMETA infrastructure. Existing users continue to use whatever
endpoints their installed binary was built against until they update.

---

## Firewall ports

| Port(s) | Protocol | Purpose | Required |
|---|---|---|---|
| 22 | TCP | SSH | Yes (or your provider's equivalent) |
| 80 | TCP | HTTP — ACME HTTP-01 challenge + redirect to 443 | Yes |
| 443 | TCP | HTTPS / WSS (signaling) | Yes |
| 3478 | TCP + UDP | STUN + TURN listener | Yes (unless deploying signaling only) |
| 49152–65535 | UDP | TURN media relay range (matches `TURN_MIN_PORT`–`TURN_MAX_PORT` in `.env`) | Yes (if coturn is deployed) |
| 5349 | TCP | TURNS (TURN over TLS) | No — disabled by default |

If your VPS provider has its own firewall in front of the host
(DigitalOcean Cloud Firewalls, Hetzner Cloud Firewall, etc.), open the
same ports there too. Both bootstrap scripts configure ufw inside the
VPS; only the provider firewall is outside their reach.

---

## Capacity notes

- **Signaling.** A 1 vCPU / 1 GiB VPS handles tens of concurrent sessions
  trivially. Each session is a few hundred bytes of JSON exchanged over
  a few seconds; signaling is not CPU-bound and not memory-bound at this
  scale. The ceiling is ulimit (open file descriptors); the default 1024
  is enough for a few hundred concurrent WS connections.
- **TURN.** Bandwidth-bound. A 1 Gbps NIC and 1 GiB RAM handle hundreds
  of concurrent relayed sessions before you saturate the link. If you
  see coturn pegging bandwidth or CPU in `htop` / `bwm-ng`, scale the
  VPS up. Most Inkternity sessions do not use TURN — direct WebRTC P2P
  + STUN handles the typical NAT scenario.
- **Co-resident with hvym_tunnler.** Steady-state RSS for the combined
  stack is ~400–700 MB (hvym uvicorn + hvym Redis + signaling + coturn
  idle + nginx). Well under 2 GiB. Both processes are async / IO-bound
  and rarely contend on a single vCPU.
- **No HA story.** If uptime requirements demand it, deploy a second
  VPS in a different region and round-robin DNS, or put a managed load
  balancer in front. The server has no state to replicate, so this is
  cheap — just IP-level routing.

---

## Cert renewal — overview

Let's Encrypt certs expire after 90 days. Certbot is installed and its
systemd timer (`certbot.timer`) handles renewal automatically — *but the
running processes will not pick up the new cert without a reload*. The
post-renewal hook is responsible for that.

Both bootstrap scripts leave you with a working `certbot renew --dry-run`.
For the full mechanics — hook installation, what to verify after the
first auto-renewal, why nginx and coturn both need restarting — see
`CERT_RENEWAL.md`.

Quick check that renewal is plumbed correctly:

```bash
sudo certbot renew --dry-run
# Expect: "Congratulations, all simulated renewals succeeded".
sudo systemctl list-timers certbot.timer
# Expect: a NEXT time within the next 12 hours.
```

---

## Troubleshooting deploys

### `certbot FAILED — verify DNS A records`

The HTTP-01 (or webroot) challenge couldn't reach the VPS. Most common
causes:

1. **DNS hasn't propagated.** `dig +short signal.heavymeta.art` from
   somewhere other than your laptop. If empty or wrong, wait for TTL.
2. **Provider firewall blocks :80.** Check the provider dashboard.
3. **Native mode, no hvym, nginx not stopped.** If running native mode
   on a fresh box, the script stops nginx before standalone certbot.
   If something else (an old default site, a previous attempt) holds
   :80, certbot will fail. `ss -tlnp | grep :80` to find the holder.

### `nginx: [emerg] cannot load certificate`

Certbot issued the cert but nginx tried to start before
`/etc/letsencrypt/live/<domain>/fullchain.pem` existed. Re-run the
bootstrap; the marker file makes reruns safe. If you're past the
marker, manually `systemctl reload nginx` after confirming the cert
files exist.

### `docker compose up -d` exits immediately

Check `docker compose logs signaling` for a Python traceback (most
likely cause: typo in `.env` or in `nginx.conf` after substitution).
Check `docker compose logs nginx` for a config syntax error.

### Signaling container restarts in a loop

Almost always a misformatted `.env` or `LOG_LEVEL=` set to something
Python's logging module doesn't recognize. `docker compose logs signaling`
shows the actual exception.

### Native mode: signaling refuses to start

```bash
journalctl -u inkternity-signaling -n 50 --no-pager
```

Look for:
- `Address already in use` — something else is on `127.0.0.1:8002` or
  `:8003`. Most likely a leftover Docker container from a previous Docker-mode
  deploy. `docker ps -a | grep inkternity` and remove.
- `Permission denied` — the venv isn't owned by `inkternity`, or `.env`
  is. `chown -R inkternity:inkternity /home/inkternity/inkternity-server`.

### `Connection refused` from a remote Inkternity client

```bash
# Confirm the TLS terminator is reachable
curl -v https://signal.heavymeta.art/health
# Confirm the WS endpoint accepts upgrades
websocat -v wss://signal.heavymeta.art/test
```

If TLS works but WS doesn't, check the nginx upstream and that the
signaling daemon is actually listening on the expected port.

### `Cert valid but Inkternity says connection refused`

Inkternity caches DNS for the session. After changing endpoints, the
user must restart the app for the new `default_p2p.json` to take effect.

---

## Co-locating with hvym_tunnler — specific notes

Read this if you're deploying to a VPS that already runs hvym_tunnler.

- **Use native mode.** Docker mode's nginx container will collide on
  :80/:443 with hvym's host nginx.
- **DNS subdomains are unrelated.** `signal.heavymeta.art` is unrelated
  to `tunnel.hvym.link`. Both point at the same VPS but they're
  served by distinct nginx server blocks, distinct certs.
- **The bootstrap will NOT reset ufw.** It only adds the TURN-specific
  rules. hvym's existing 22/80/443 rules are preserved.
- **`/var/www/acme` is shared.** Both stacks issue certs via webroot
  through this single ACME-challenge directory. hvym created it; the
  native bootstrap reuses it. Do not delete it.
- **TURN bandwidth competes with hvym tunneling.** If both stacks are
  active and one is bandwidth-heavy, the other suffers. Watch
  `bwm-ng` / `vnstat`. If contention is real, move one stack to a
  separate VPS.
- **Certbot timer renews both.** A single `certbot renew` run handles
  all certs on the host. Your deploy hook needs to reload nginx AND
  restart coturn (the latter doesn't automatically pick up cert changes).
  See `CERT_RENEWAL.md` for the hook content.
- **hvym's auto-renewal is also acme-dns-based for its wildcard cert.**
  That's a separate flow; the inkternity certs use HTTP-01 webroot.
  Both work in parallel.

---

## Capacity and scaling — when to grow

| Symptom | What to do |
|---|---|
| coturn pegging the NIC during peak hours | Move coturn to a dedicated higher-bandwidth VPS. Update `default_p2p.json`'s `turnList`. Ship a new Inkternity build. |
| Signaling daemon CPU > 50% sustained | Profile the WS relay; likely a misbehaving client flooding messages. Add nginx `limit_req` per IP. |
| Open file descriptors hitting 1024 | Raise the systemd unit's `LimitNOFILE=`. The signaling protocol holds one FD per connected client. |
| Latency on signaling exchange > 1s | Network issue, not server issue — signaling is microseconds. Investigate VPS provider routing. |

For Phase 0 scale (tens of concurrent canvases at most), none of the
above is expected. Plan to revisit when growth justifies it.

---

## Reference: ports and processes after a successful deploy

### Docker mode

```
$ ss -tlnp | grep -E ':80|:443|:3478'
LISTEN 0  511  0.0.0.0:80     0.0.0.0:*  users:(("nginx",pid=...))
LISTEN 0  511  0.0.0.0:443    0.0.0.0:*  users:(("nginx",pid=...))
LISTEN 0  128  0.0.0.0:3478   0.0.0.0:*  users:(("turnserver",pid=...))

$ docker compose ps
NAME                    STATUS    PORTS
inkternity-signaling    Up        8000-8001/tcp
inkternity-nginx        Up        0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp
inkternity-coturn       Up        (host networking)
```

### Native mode

```
$ ss -tlnp | grep -E ':80|:443|:3478|:8002|:8003'
LISTEN 0  511  0.0.0.0:80          0.0.0.0:*  users:(("nginx",pid=...))
LISTEN 0  511  0.0.0.0:443         0.0.0.0:*  users:(("nginx",pid=...))
LISTEN 0  128  0.0.0.0:3478        0.0.0.0:*  users:(("turnserver",pid=...))
LISTEN 0  128  127.0.0.1:8002      0.0.0.0:*  users:(("python3",pid=...))
LISTEN 0  128  127.0.0.1:8003      0.0.0.0:*  users:(("python3",pid=...))

$ systemctl is-active inkternity-signaling coturn nginx
active
active
active
```
