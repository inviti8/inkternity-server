# Deployment Guide

## Prerequisites

- A VPS with a public IPv4 address. Tested target: Ubuntu 22.04. ~$5–10/month from any major provider works (DigitalOcean, Hetzner, Vultr, Linode). Existing HEAVYMETA infrastructure (e.g., the `tunnel.hvym.link` host) can co-locate this stack if it has spare capacity.
- DNS A records for both endpoints pointing at the VPS:
  - `signal.heavymeta.art` → VPS IP
  - `turn.heavymeta.art` → VPS IP
  - DNS must propagate before running the bootstrap (certbot's HTTP-01 challenge will fail otherwise).
- Email address for Let's Encrypt registration.

## One-shot deployment

```bash
# Edit DOMAIN_SIGNAL, DOMAIN_TURN, LETSENCRYPT_EMAIL, REPO_URL near the top
nano scripts/vps_startup.sh

# Run as root
sudo ./scripts/vps_startup.sh
```

The bootstrap script (~10 minutes on a fresh VPS):

1. Installs Docker, certbot, and ufw.
2. Creates an unprivileged `inkternity` user.
3. Clones this repo to `/home/inkternity/inkternity-server`.
4. Generates a `.env` with a fresh random TURN secret.
5. Substitutes the configured domains into `nginx/nginx.conf` and the TURN credentials into `coturn/turnserver.conf`.
6. Configures the firewall: 22 TCP, 80 TCP, 443 TCP, 3478 TCP+UDP, 49152–65535 UDP for media relays.
7. Requests Let's Encrypt certs via certbot's standalone HTTP-01 mode.
8. Builds and starts the docker-compose stack.

When it's done, you'll see the signaling URL and the generated TURN secret. **Save the TURN secret** — it goes into Inkternity's `assets/data/config/default_p2p.json`.

## Pointing Inkternity at the new infrastructure

Edit `assets/data/config/default_p2p.json` in the Inkternity tree (or the deployed config in a user's `~/.var/app/...` config dir for already-installed users):

```json
{
    "signalingServer": "wss://signal.heavymeta.art",
    "stunList": [
        "stun.l.google.com:19302",
        "stun1.l.google.com:19302"
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

Rebuild + ship the Inkternity binary; new sessions will route entirely through HEAVYMETA infrastructure.

## Cert renewal

Let's Encrypt certs expire after 90 days. Certbot installed by the bootstrap auto-renews via the systemd `certbot.timer`. After a successful renewal, restart nginx + coturn to pick up the new certs:

```bash
# Cron / systemd hook (add to /etc/letsencrypt/renewal-hooks/post/restart-inkternity.sh)
#!/bin/bash
docker compose -f /home/inkternity/inkternity-server/docker-compose.yml restart nginx coturn
```

Test renewal flow manually:

```bash
sudo certbot renew --dry-run
```

## Local dev (no VPS, no TLS, no TURN)

Validate the production-shape stack on your dev machine before pushing to a real VPS. Uses `docker-compose.dev.yml` as an overlay that:

- Binds `signaling` directly to `127.0.0.1:8000` (and `:8001` for the health endpoint), so Inkternity's local `p2p.json` (`ws://localhost:8000`) connects unchanged.
- Skips `nginx` and `coturn` via the `prod` profile — locally there are no Let's Encrypt certs to mount, and TURN can't relay over loopback anyway.

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml build signaling
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d signaling
curl http://localhost:8001/health   # should print "ok"
```

Stop with `docker compose down`. To run the full prod-shape stack locally (with nginx + coturn), pass `--profile prod`:

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml --profile prod up -d
```

That last form requires `/etc/letsencrypt` certs and is generally only useful on the actual VPS via `vps_startup.sh`.

## Operations

```bash
# Status
docker compose ps

# Tail signaling logs
docker compose logs -f signaling

# Tail coturn logs
docker compose logs -f coturn

# Restart the whole stack (e.g., after editing nginx.conf)
docker compose restart

# Rotate the TURN secret (forces all Inkternity clients to be re-shipped)
sudo ./scripts/rotate_turn_secret.sh
```

## Firewall ports

| Port(s) | Protocol | Purpose |
|---|---|---|
| 22 | TCP | SSH |
| 80 | TCP | HTTP (ACME challenge + redirect to HTTPS) |
| 443 | TCP | HTTPS / WSS (signaling) |
| 3478 | TCP + UDP | TURN/STUN listener |
| 49152–65535 | UDP | TURN media relay range (matches `TURN_MIN_PORT`–`TURN_MAX_PORT` in `.env`) |

If your VPS provider has its own firewall in front of the host (DigitalOcean Cloud Firewalls, Hetzner Cloud Firewall, etc.), open the same ports there too.

## Capacity notes

- Single small VPS (1 vCPU / 1 GB RAM) handles tens of concurrent signaling sessions trivially. Signaling is just message-passing; no per-session compute.
- coturn TURN-relay capacity is bandwidth-bound. A 1 Gbps NIC and 1 GB RAM handle ~hundreds of concurrent relayed sessions. Scale the VPS up if `htop`/`bwm-ng` show coturn pegging the bandwidth or a CPU.
- Most Inkternity sessions never use TURN — direct WebRTC P2P + STUN handles the majority of NAT scenarios. TURN is fallback only.
- No clustering or HA story in this repo; deploy a second VPS in a different region and round-robin DNS if uptime requirements demand it.

## Co-locating with hvym_tunnler

If you're deploying alongside an existing `hvym_tunnler` host:

- Use distinct subdomains (`signal.heavymeta.art` is unrelated to `tunnel.hvym.link`).
- The two stacks both use Docker compose; they don't conflict on container names, networks, or volumes.
- Both bind nginx to :80/:443 — you'll need to merge the nginx configs (one shared nginx container serving both `tunnel.*` and `signal.*` virtual hosts) or run nginx outside Docker as the host's reverse proxy with both stacks behind it.
- coturn binds to host networking on :3478 + the wide UDP range. If hvym_tunnler is the only other resident, no conflict.
