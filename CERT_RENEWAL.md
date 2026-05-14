# Inkternity Server — Cert Renewal

Mechanics of Let's Encrypt certificate renewal for the
`signal.hvym.link` (and optionally `turn.hvym.link`) certs. If
you only want "does renewal work?" — run `sudo certbot renew --dry-run`
and stop reading. If you want to understand what happens, why it can
silently break, and how to verify it after a reboot or upgrade, read on.

For the production-domain hvym_tunnler wildcard renewal flow (acme-dns
DNS-01, totally different mechanism), see `hvym_tunnler/CERT_RENEWAL.md`.
This doc is HTTP-01 only.

---

## 1. What's deployed

Both bootstrap scripts (`scripts/vps_startup.sh` and
`scripts/vps_startup_native.sh`) issue certificates via Let's Encrypt's
HTTP-01 challenge and configure certbot to renew automatically. After
a successful bootstrap, you have:

| Artifact | Location | Purpose |
|---|---|---|
| Cert + key | `/etc/letsencrypt/live/<DOMAIN_SIGNAL>/` | The actual certificate files. Symlinks into `/etc/letsencrypt/archive/<DOMAIN_SIGNAL>/`. |
| Renewal config | `/etc/letsencrypt/renewal/<DOMAIN_SIGNAL>.conf` | Tells certbot how this cert was originally issued (`authenticator = standalone` or `webroot`). Determines how renewals happen. |
| Renewal timer | `certbot.timer` (systemd) | Runs `certbot renew` twice daily. Pre-installed by the `certbot` apt package. |
| Renewal cron (alternative) | `/etc/cron.d/certbot` | Same purpose as the timer. Ubuntu 22.04 prefers the timer; both may exist harmlessly. |

`certbot renew` is a no-op on certs that have more than 30 days of
validity left. It only attempts a real renewal in the final 30-day
window. This is why the timer runs twice daily: lots of cheap no-ops,
guaranteed to catch the cert before expiry.

## 2. The thing that silently breaks renewal

A successful renewal writes new cert files to `/etc/letsencrypt/live/<DOMAIN>/`.
But running processes — nginx, coturn — only read those files on
startup. **They will keep serving the old cert until they're told to
reload.**

A cert can renew successfully on disk and still expire from the client's
perspective if nothing restarts the consumers. This is the #1
"renewal silently broke" failure mode. The fix is a *deploy hook*: a
shell script certbot runs after every successful renewal.

Both deploy paths install one. Verify it exists:

```bash
ls /etc/letsencrypt/renewal-hooks/deploy/
```

You should see at least `reload-inkternity.sh`. Its contents (the
Docker-mode and native-mode bootstraps install equivalent versions):

**Docker mode** — `/etc/letsencrypt/renewal-hooks/deploy/reload-inkternity.sh`:

```bash
#!/bin/bash
# Reload nginx + coturn so they pick up the renewed certificate.
cd /home/inkternity/inkternity-server || exit 0
docker compose restart nginx coturn
```

**Native mode** — same path, different contents:

```bash
#!/bin/bash
# Reload host nginx + restart coturn so they pick up the renewed cert.
systemctl reload nginx       || true
systemctl restart coturn     || true
```

In both cases the file must be executable (`chmod +x`). If the bootstrap
didn't install the hook for some reason, create it manually with the
above content and `chmod 755` it.

> **Why coturn needs a restart, not a reload:** coturn does not
> implement a `SIGHUP`-style config reload. The only way to pick up
> a new cert is to restart the process. Brief downtime (1–2 seconds);
> in-flight relays drop and the next ICE check-list cycle reconnects
> them.

## 3. Verifying renewal works

Run this *before* the cert is anywhere near expiry. Both bootstraps
already exercise the path, but it's worth doing manually after first
deploy and after any nginx/firewall change:

```bash
sudo certbot renew --dry-run
```

Expected last lines:

```
Congratulations, all simulated renewals succeeded:
  /etc/letsencrypt/live/signal.hvym.link/fullchain.pem (success)
```

If you see `Challenge failed` or `Connection refused`, the renewal path
is broken — see §6 below.

### Verify the timer is active

```bash
systemctl list-timers certbot.timer
```

Expected:

```
NEXT                         LEFT     LAST                         PASSED  UNIT
YYYY-MM-DD HH:MM:SS UTC      Xh left  YYYY-MM-DD HH:MM:SS UTC      Yh ago  certbot.timer
```

If `NEXT` is more than 12 hours away, something's off — the package
default is "twice daily, randomized."

### Verify the deploy hook executes

Run a real renewal cycle in dry-run mode and confirm the hook fires:

```bash
sudo certbot renew --dry-run --deploy-hook 'echo "would reload"' 2>&1 | grep "would reload"
```

`certbot renew` only invokes deploy hooks on actual renewals, not
dry-runs — so the above invokes the override hook explicitly. The
permanent hooks in `/etc/letsencrypt/renewal-hooks/deploy/` fire only
when a real renewal succeeds.

## 4. What happens on the day of renewal

A timeline for the operator's mental model:

- **T-30 days.** Certbot timer fires. Certificate has 30 days of
  validity left. certbot decides this is the renewal window. It runs
  the configured challenge (HTTP-01 standalone or webroot — depending
  on how the original was issued).
- **HTTP-01 challenge.** Let's Encrypt's servers send a GET to
  `http://<DOMAIN>/.well-known/acme-challenge/<TOKEN>`. The challenge
  responder (standalone certbot binding :80 briefly, or the running
  nginx serving the webroot dir) returns the expected response.
- **Cert issued.** Let's Encrypt returns a fresh cert + key. certbot
  writes them to `/etc/letsencrypt/live/<DOMAIN>/`.
- **Deploy hook runs.** `reload-inkternity.sh` restarts nginx + coturn
  (or the Docker-mode equivalents). New cert is now in memory.
- **Done.** Cert is now valid for another 90 days. Old cert is in
  `/etc/letsencrypt/archive/<DOMAIN>/<N-1>/` for forensics.

Total wall-clock time: 10–30 seconds. Service is uninterrupted
(reload, not restart, for nginx); coturn has a brief gap.

## 5. Differences between modes

### Docker mode

- Cert issuance: `certbot certonly --standalone` at bootstrap time.
- Renewal mechanism: same — `--standalone`. The renewal cycle briefly
  binds :80, so the script stops the nginx container, runs certbot,
  and restarts nginx via the deploy hook.
- The bootstrap script handles this; `certbot renew --dry-run` exercises
  the same path.

### Native mode (co-resident with hvym_tunnler)

- Cert issuance: `certbot certonly --webroot -w /var/www/acme` at
  bootstrap time.
- Renewal mechanism: same — `--webroot`. No process disruption;
  the host nginx keeps serving :80 throughout. Let's Encrypt's
  validator reads the challenge file written to `/var/www/acme`.
- The deploy hook reloads nginx (cert change → nginx in-memory cert
  is stale) and restarts coturn.

### Native mode (standalone, no hvym)

- Cert issuance: `certbot certonly --standalone`, briefly stopping
  nginx.
- Renewal: same; the standalone authenticator stops nginx itself.
  Brief nginx downtime during renewal — a few seconds.

The renewal config file at `/etc/letsencrypt/renewal/<DOMAIN>.conf`
records which authenticator was used. Don't hand-edit it.

## 6. When renewal fails

### `Challenge failed for domain signal.hvym.link`

Let's Encrypt couldn't reach the challenge URL. Causes:

1. **DNS changed.** A record no longer points at this VPS. `dig +short signal.hvym.link`.
2. **Firewall blocking :80.** UFW or provider firewall. `ufw status` /
   provider dashboard.
3. **nginx config drifted.** Webroot mode: confirm the `/.well-known/acme-challenge/`
   location is still served from `/var/www/acme` in whichever nginx is on :80
   (hvym's default_server or yours).
4. **Webroot doesn't exist or is unwritable by certbot.** `ls -ld /var/www/acme`.

Reproduce in isolation:

```bash
# Write a test file to the webroot
sudo bash -c 'echo "test" > /var/www/acme/test'
# Hit it via the public URL
curl -i http://signal.hvym.link/.well-known/acme-challenge/test
# Expect: 200 OK, body "test"
sudo rm /var/www/acme/test
```

If the curl fails, the issue is between Let's Encrypt and your nginx —
the cert problem is downstream of a broken HTTP path.

### `Permission denied` writing to renewal config

certbot runs as root. If it can't write to `/etc/letsencrypt/`,
something has changed permissions there — restore with:

```bash
sudo chown -R root:root /etc/letsencrypt
sudo chmod -R 755 /etc/letsencrypt
sudo chmod 600 /etc/letsencrypt/archive/*/privkey*.pem
```

### Cert renewed but nginx/coturn still serving old cert

Deploy hook didn't run, or it ran but the reload failed silently. Check:

```bash
journalctl --since "1 hour ago" | grep -i certbot
ls -l /etc/letsencrypt/live/signal.hvym.link/
# Inspect the cert nginx is actually serving:
echo | openssl s_client -servername signal.hvym.link \
    -connect signal.hvym.link:443 2>/dev/null \
    | openssl x509 -noout -dates
```

If the served cert's `notAfter` is the old date, run the hook manually:

```bash
sudo /etc/letsencrypt/renewal-hooks/deploy/reload-inkternity.sh
```

### Cert expires while you're not looking

If the cert actually expires (90+ days without renewal, e.g. because
the timer was disabled), Inkternity clients can't connect over WSS. To
recover:

```bash
# Native mode
sudo certbot certonly --webroot -w /var/www/acme --force-renewal \
    -d signal.hvym.link -d turn.hvym.link
sudo systemctl reload nginx
sudo systemctl restart coturn

# Docker mode
cd /home/inkternity/inkternity-server
sudo docker compose stop nginx
sudo certbot certonly --standalone --force-renewal \
    -d signal.hvym.link -d turn.hvym.link
sudo docker compose up -d nginx coturn
```

After recovery, re-enable the timer:

```bash
sudo systemctl enable --now certbot.timer
```

## 7. Adding TURNS (TLS over coturn)

If/when you enable TURNS on port 5349, you'll want a cert for the
TURN domain too. Both bootstrap scripts already issue certs for
`$DOMAIN_TURN` as part of the same renewal record, so the cert is
already on disk at `/etc/letsencrypt/live/<DOMAIN_TURN>/` if you
followed the default config.

To activate TURNS:

1. In `coturn/turnserver.conf`, uncomment the three TLS lines:
   ```
   tls-listening-port=5349
   cert=/etc/coturn/certs/fullchain.pem
   pkey=/etc/coturn/certs/privkey.pem
   ```
2. **Docker mode.** The cert mount is already configured in
   `docker-compose.yml` (`/etc/letsencrypt/live/${DOMAIN_TURN}` is
   mounted at `/etc/coturn/certs`). Just `docker compose restart coturn`.
3. **Native mode.** coturn reads certs directly from
   `/etc/letsencrypt/live/<DOMAIN_TURN>/`. Update the `cert=` /
   `pkey=` lines to that absolute path and `systemctl restart coturn`.
4. Open port 5349/TCP in ufw and provider firewall.
5. Add a TURNS entry to Inkternity's `default_p2p.json`:
   ```json
   {"url": "turns:turn.hvym.link", "port": 5349, ...}
   ```

The renewal flow is the same — certbot renews; the deploy hook
restarts coturn, which picks up the new cert.

## 8. Forensics: history of renewals

```bash
sudo journalctl -u certbot.service --since "30 days ago" --no-pager | tail -50
```

For long-term history, certbot writes to `/var/log/letsencrypt/` (one
log file per invocation, rotated weekly by default).

```bash
ls -lt /var/log/letsencrypt/ | head -10
```

Read the most recent files for the actual challenge response logs.
Useful when a renewal failed and you want to know which DNS / network
condition tripped it.

## 9. Manual renewal (don't, but if you must)

You should never need this — the timer + deploy hook is fully
unattended. But if for some reason you want to force a renewal *right now*:

```bash
sudo certbot renew --force-renewal -d signal.hvym.link -d turn.hvym.link
```

`--force-renewal` skips the 30-days-remaining heuristic. The deploy
hook will still run and reload nginx + coturn.

Avoid running `--force-renewal` in scripted automation. You can hit
Let's Encrypt's rate limit (5 duplicate certs per week per domain set,
50 per week per registered domain). The timer's "renew when 30 days
remain" heuristic exists specifically to keep you under that.
