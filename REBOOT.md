# Inkternity Server — Post-Reboot Verification

Run these checks after rebooting the VPS (kernel upgrade, security patch,
provider-initiated reboot, suspected hang) to confirm the stack came
back up cleanly. Most rebooting goes fine — both deployment modes are
designed to recover unattended — but the checklist exists so you can
catch the cases where it doesn't.

Production domains:

- `signal.hvym.link` — signaling (WSS)
- `turn.hvym.link` — coturn (TURN/STUN)

There are two layers of checks:

1. **Remote checks** — from your machine. Hits public endpoints; verifies
   the service is reachable end-to-end (DNS → nginx → app).
2. **On-server checks** — SSH into the VPS. Inspects systemd / Docker
   state and logs.

Start with remote checks. If everything passes, you're done. Only SSH
in if something fails or you want belt-and-suspenders.

---

## 1. Remote checks (from your machine)

No auth required; all endpoints are public.

### 1.1 Signaling health

```bash
curl -s https://signal.hvym.link/health
# Expected: ok
```

A non-200 (or no response) means something between the public internet
and the signaling daemon is broken — TLS, nginx, the daemon itself, or
DNS.

### 1.2 TLS certificate validity

```bash
echo | openssl s_client -servername signal.hvym.link \
    -connect signal.hvym.link:443 2>/dev/null \
    | openssl x509 -noout -dates -subject
```

Expected:

```
notBefore=…
notAfter=…           # at least 30 days in the future
subject=CN = signal.hvym.link
```

`notAfter` within the next 30 days means cert renewal hasn't been
fixing things — see `CERT_RENEWAL.md`.

### 1.3 Security headers

```bash
curl -sI https://signal.hvym.link/health \
    | grep -iE 'strict-transport-security|x-frame-options|x-content-type-options'
```

Expected: all three headers present. If missing in native mode, your
sites-enabled config drifted — `cat /etc/nginx/sites-enabled/inkternity-signaling`
to confirm. (Docker mode's `nginx/nginx.conf` doesn't currently set
these headers; that's a known gap and not blocking.)

### 1.4 WebSocket reachability

```bash
# Needs websocat: cargo install websocat, or apt install websocat
websocat -v wss://signal.hvym.link/_reboot_smoke_test
# Expected: connection opens. Type Ctrl-C to disconnect.
```

If the connection opens, signaling is alive. If it errors with
`Bad handshake` or `HTTP 502`, nginx is reachable but can't talk
upstream to the signaling daemon.

### 1.5 TURN reachability

```bash
# STUN port: should respond to any UDP packet with a binding response.
# Quick smoke test with netcat:
echo | nc -u -w 2 turn.hvym.link 3478
# nc will exit silently after 2s if coturn responds, or hang/error otherwise.

# Better: use a STUN client like stuntman's `stunclient`:
stunclient turn.hvym.link 3478
# Expected: "Binding test: success" + your public IP.
```

Most operators skip this — `coturn` being up implies the systemd /
Docker check below passed, and if TURN is really broken users will
report inability to connect from restrictive networks.

---

## 2. On-server checks (SSH into the VPS)

Only run if §1 surfaced a problem, or after a major upgrade.

```bash
ssh root@<vps-ip>
```

### 2.1 Service status

**Docker mode:**

```bash
cd /home/inkternity/inkternity-server
docker compose ps
```

Expected: all three services (`signaling`, `nginx`, `coturn`) in `Up`
state. Look for `Restarting` or `Exit ...` — those indicate the
service is crash-looping.

**Native mode:**

```bash
systemctl is-active inkternity-signaling && echo "signaling: OK" || echo "signaling: FAILED"
systemctl is-active coturn               && echo "coturn:    OK" || echo "coturn:    FAILED"
systemctl is-active nginx                && echo "nginx:     OK" || echo "nginx:     FAILED"
```

All three should print `OK`. If any prints `FAILED`, jump to §2.4 for
its logs.

### 2.2 Listening ports

```bash
sudo ss -tlnp | grep -E ':80|:443|:3478|:8002|:8003'
sudo ss -ulnp | grep -E ':3478|:4915[2-9]|:[5-6][0-9]{4}'
```

Expected, native mode:

| Port | Bound by |
|---|---|
| 80, 443 | `nginx` |
| 3478 TCP | `turnserver` |
| 3478 UDP | `turnserver` |
| 8002 (127.0.0.1) | `python3` (signaling WS) |
| 8003 (127.0.0.1) | `python3` (signaling health) |
| 49152–65535 UDP (selection) | `turnserver` (relay sockets, only bound while sessions are active) |

Expected, Docker mode:

| Port | Bound by |
|---|---|
| 80, 443 | `nginx` (in container, published to host) |
| 3478 TCP+UDP | `turnserver` (host networking) |
| 49152–65535 UDP | `turnserver` (host networking) |
| 8000-8001 | NOT bound on host — internal to compose bridge |

If a port that should be bound is missing, the corresponding service is
down. If a *different* PID is bound to a port (e.g., the old Docker
nginx is still up after switching to native mode), that's the source
of the conflict.

### 2.3 Disk + memory + load

```bash
df -h /
free -m
uptime
```

Tripwires:

- `df`: root partition >90% full → log rotation may be lagging; check
  `/var/log/journal/` and `docker system df`.
- `free`: <100 MB available → a process is leaking. Top candidates:
  signaling (look at peer-count log lines; a leak would correlate with
  unbounded growth in `active=N`), coturn (rare), or a runaway log.
- `uptime`: load average sustained > vCPU count → CPU saturation.
  Signaling is async and rarely the cause; usually it's coturn handling
  unexpected relay volume.

### 2.4 Logs

```bash
# Native mode
journalctl -u inkternity-signaling --since "10 minutes ago" --no-pager
journalctl -u coturn               --since "10 minutes ago" --no-pager | tail -50
journalctl -u nginx                --since "10 minutes ago" --no-pager

# Docker mode
cd /home/inkternity/inkternity-server
docker compose logs --since 10m signaling
docker compose logs --since 10m nginx
docker compose logs --since 10m coturn
```

What's normal in signaling logs:

```
[INFO] connected id=<globalID> (active=N)
[INFO] disconnected id=<globalID> (active=N)
```

Anything `[ERROR]` is worth investigating. `[WARNING] dropping non-JSON
message from id=…` at low volume is expected (scanners, buggy clients).
At sustained high volume, see `SECURITY.md` §3.1.

### 2.5 Cert age

```bash
sudo certbot certificates
```

Expected: `VALID: NN days` for each cert. Anything under 30 days that
isn't actively renewing means the renewal flow is broken — see
`CERT_RENEWAL.md`.

### 2.6 Firewall state

```bash
sudo ufw status verbose
```

Expected rules (native mode, co-resident with hvym):

```
22/tcp                ALLOW       Anywhere           (hvym's; do not remove)
80/tcp                ALLOW       Anywhere           (hvym's; do not remove)
443/tcp               ALLOW       Anywhere           (hvym's; do not remove)
3478/tcp              ALLOW       Anywhere           # TURN/STUN TCP
3478/udp              ALLOW       Anywhere           # TURN/STUN UDP
49152:65535/udp       ALLOW       Anywhere           # TURN media relays
```

Expected rules (Docker mode, no hvym):

```
22/tcp, 80/tcp, 443/tcp, 3478/tcp, 3478/udp, 49152:65535/udp — all ALLOW.
```

If ufw is inactive (`Status: inactive`), traffic isn't actually
firewalled. Re-run the bootstrap or `ufw enable` after sanity-checking
the rules.

---

## 3. What to do when something is broken

### Signaling daemon won't start (native mode)

```bash
journalctl -u inkternity-signaling -n 50 --no-pager
```

Most common causes after a reboot:

1. **`Address already in use`** — the bound ports (`8002`, `8003`) are
   held by something else. Most likely a stale `python3` from a previous
   start. `ps aux | grep server.py` to find it; `kill` it if needed.
2. **`No module named websockets`** — the venv got blown away (some
   maintenance / Ansible run). Re-create:
   ```bash
   cd /home/inkternity/inkternity-server
   sudo -u inkternity python3 -m venv venv
   sudo -u inkternity venv/bin/pip install -r signaling/requirements.txt
   sudo systemctl start inkternity-signaling
   ```
3. **`.env` missing or malformed** — `cat /home/inkternity/inkternity-server/.env`.
   Should have `LISTEN_HOST=`, `LISTEN_PORT=`, `LOG_LEVEL=` at minimum.

### Docker stack won't start

```bash
cd /home/inkternity/inkternity-server
docker compose ps
docker compose logs --tail 100
```

Most common causes:

1. **Cert volume missing** — `/etc/letsencrypt/live/$DOMAIN_SIGNAL/`
   has been removed or unreachable. nginx container won't start. Check
   `ls -la /etc/letsencrypt/live/`.
2. **Image gone** — `docker images | grep inkternity` to confirm.
   Rebuild: `docker compose build && docker compose up -d`.
3. **Network conflict** — `docker network ls`. If `inkternity-network`
   conflicts with a manually created network, `docker network rm` the
   stray one.

### nginx config rejected after a reboot

```bash
sudo nginx -t
```

Tells you exactly which file and line. Common causes:

1. A cert symlink became dangling (cert was manually removed). Re-run
   certbot to restore.
2. Someone hand-edited `/etc/nginx/sites-available/inkternity-signaling`
   and broke the syntax. Restore from the repo:
   ```bash
   sudo sed "s/signal\.heavymeta\.art/<DOMAIN_SIGNAL>/g" \
       /home/inkternity/inkternity-server/nginx/inkternity-signaling.conf \
       > /etc/nginx/sites-available/inkternity-signaling
   sudo nginx -t && sudo systemctl reload nginx
   ```

### coturn won't start

```bash
journalctl -u coturn -n 50
```

Look for:

1. **`Cannot read configuration file`** — `/etc/turnserver.conf` is
   missing or malformed. Restore from the repo (with `__TURN_*__`
   substituted from `.env`).
2. **`TURNSERVER_ENABLED=0` in /etc/default/coturn** — the bootstrap
   should have flipped this. `grep TURNSERVER_ENABLED /etc/default/coturn`
   and re-flip if needed.
3. **`bind: Address already in use`** — something else (a stray
   Docker coturn container, perhaps) holds :3478. `docker ps -a | grep coturn`
   and remove.

### TLS handshake fails after a reboot

```bash
# Confirm certs are still on disk
sudo ls -la /etc/letsencrypt/live/signal.hvym.link/

# Confirm nginx is reading them
sudo nginx -T 2>/dev/null | grep -A1 ssl_certificate
```

If nginx is pointing at the right cert files but the served cert is
old, reload (native) or restart (Docker) nginx — the in-memory cert
didn't refresh. This is what the renewal deploy hook normally handles.

---

## 4. Reboot checklist (one-liner version)

For repeat operators who don't need the long form. Run these after
every planned reboot:

```bash
# Remote, from your laptop:
curl -s https://signal.hvym.link/health \
    && echo | openssl s_client -servername signal.hvym.link \
       -connect signal.hvym.link:443 2>/dev/null \
       | openssl x509 -noout -dates

# On the VPS:
systemctl is-active inkternity-signaling coturn nginx \
    && sudo ufw status | grep -E '3478|4915'
```

If both lines exit clean and the cert `notAfter` is well in the
future, you're good.

---

## 5. What auto-recovers and what doesn't

| Failure mode | Auto-recovers? | Why / how |
|---|---|---|
| VPS rebooted | Yes | Both modes use systemd / Docker `restart: unless-stopped`. Native: `inkternity-signaling.service` and `coturn.service` enabled at boot. Docker: compose stack auto-starts via the docker service. |
| Signaling daemon crash | Yes | `Restart=always RestartSec=5` (native) or `restart: unless-stopped` (Docker). |
| coturn crash | Yes | Same. |
| nginx config typo (post-edit) | No | nginx refuses to reload; old config keeps serving. You only notice on the next reboot. Always `nginx -t` after edits. |
| Cert expired | No (without timer) | Renewal timer + deploy hook prevents this if installed and running. If the timer was disabled (e.g., by a maintenance script), cert expires silently. |
| Disk full | No | systemd journals can fill `/var` and stall logging; signaling itself can still run. Watch `df`. |
| TURN secret leaked | No — manual | Rotate via `scripts/rotate_turn_secret.sh`. |
| Process pinned-CPU loop | Sometimes | If `Restart=always` triggers because the process actually died — yes. If the process is unkillable in a tight loop — no. Hard reboot in that case. |
