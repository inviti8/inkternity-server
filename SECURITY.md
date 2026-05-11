# Inkternity Server — Security Notes

A short, operational threat model for the deployed stack. Aimed at someone
who has read `ARCHITECTURE.md` and now needs to reason about what could
go wrong and what to do about it.

This is not a formal security audit. It is the kind of document you write
so that the next person who deploys, rotates a secret, or investigates a
suspicious log line has the same mental model you did.

---

## 1. Trust model recap

Re-stated from `ARCHITECTURE.md` because everything below depends on it:

- **The signaling server is anonymous and stateless.** Anyone with the
  WSS URL can connect, name themselves anything, and send arbitrary JSON.
  This is by design.
- **Trust lives in the Inkternity desktop client**, not here. The client
  verifies signed Phase 0 access tokens (Stellar JWTs from the HEAVYMETA
  portal) after the WebRTC channel is established. A compromised
  signaling server cannot subvert that check.
- **WebRTC payloads are end-to-end encrypted** (DTLS-SRTP) between peers.
  Neither the signaling server nor the TURN server can decrypt them. TURN
  sees ciphertext only.

The implication: most of the security surface is the same as any
internet-facing nginx + a couple of Python/coturn processes — TLS hygiene,
patch level, firewall, and not leaking the TURN credential.

## 2. Exposed surface

What is reachable from the public internet:

| Port | Protocol | Service | Notes |
|---|---|---|---|
| 22 | TCP | SSH | The provider's, not ours. Harden per your provider's defaults — disable root password login, key-only auth, fail2ban if you want it. |
| 80 | TCP | nginx | ACME HTTP-01 challenge + 301-redirect to 443. No other endpoints. |
| 443 | TCP | nginx → signaling | WSS upgrade for `/<globalID>`. HTTPS GET on `/health`. Everything else returns whatever nginx returns by default (404 if you didn't add a block, the WS handshake error if you did). |
| 3478 | TCP + UDP | coturn | STUN + TURN listener. Long-term static credentials required to relay. |
| 49152–65535 | UDP | coturn relays | Wide range of media-relay sockets. Bound dynamically per session. |
| (5349) | TCP | coturn TURNS | Not enabled in default config. See `ARCHITECTURE.md` §3 for when to add. |

Anything not listed should not be reachable. The deploy scripts configure
ufw to match this set; if you bring up the stack without running them,
double-check with `ss -tlnp` and `ss -ulnp` afterward.

## 3. What an attacker can do, ranked

The realistic abuse cases, in rough order of likelihood:

### 3.1 Send junk to the signaling server

Anyone can open a WSS connection and send malformed JSON, oversized
frames, or messages addressed to globalIDs that aren't online. The
relay code drops invalid messages silently and logs at WARNING.

**Impact:** Wastes a small amount of CPU and log volume. Could plausibly
degrade service for legitimate clients if sustained at very high volume.

**Mitigations in repo:** none currently. The relay is intentionally
minimal.

**Mitigations to add if abuse becomes real:** rate-limit per IP at nginx
(`limit_conn` + `limit_req`); set a hard cap on message size in the WS
server; alert on the WARNING log volume.

### 3.2 Impersonate a globalID

An attacker who knows a target's globalID can open a WSS connection with
that same globalID in the URL path. The server's "replace prior
connection" logic will close the legitimate client's socket
(`code=1000, reason="superseded"`) and route subsequent messages to the
attacker.

**Impact:** The attacker can receive offers / answers / ICE candidates
addressed to that globalID, and inject their own outbound. This is bad
because it lets them inject themselves into the *signaling* of a session.

**Why this isn't a session compromise:** the WebRTC handshake includes
DTLS fingerprint pinning inside the SDP. If the attacker doesn't have
the legitimate peer's private key, they can't produce SDP that the other
side will accept as the original. The data channel will refuse to form.
At worst the attacker can DoS the session by making the legitimate peer's
SDP get ignored.

**Why this is still worth fixing eventually:** globalIDs are 40 random
hex chars — not guessable, but anyone who has ever seen one (a logged
URL, a debugging dump) has it forever. Phase 0.5 should add a
challenge/response that proves possession of the app keypair before
accepting a globalID.

**Mitigation in repo:** none. Phase 0 design decision.

### 3.3 Use the TURN server as an open relay

If the TURN static credential leaks (committed to a public repo,
exfiltrated from a user's `default_p2p.json`, captured in transit before
TLS), an attacker can pay your bandwidth to relay arbitrary UDP traffic
to arbitrary destinations.

**Impact:** Bandwidth bill. In extreme cases, your IP gets listed as a
source of abuse (mass-scan traffic, DDoS reflection) because TURN looks
like a generic open relay to receivers. No content compromise — TURN
can't decrypt anything.

**Mitigations in repo:**

- `turnserver.conf` denies relay to RFC1918 + link-local + loopback
  ranges, so the TURN server cannot be abused to scan the internal
  network behind it.
- TURN credentials are static long-term, generated as 32 hex bytes
  (`openssl rand -hex 32`). Not guessable.
- `scripts/rotate_turn_secret.sh` regenerates the secret, updates `.env`,
  restarts coturn, and prints the new secret for inclusion in Inkternity's
  `default_p2p.json`. After rotation, old binaries can't use the TURN
  server; ship a new Inkternity build to keep clients working.

**Operational practice:** treat `TURN_SECRET` in `.env` as credential
material. Do not commit it. Do not put it in screenshots, in bug reports,
in cloud-init user data that gets logged. Rotate after any suspected
exposure (a teammate's laptop is lost, the repo accidentally goes public,
etc.).

### 3.4 DoS the VPS

A 1 vCPU / 1–2 GiB VPS has no real defense against a sustained DDoS. coturn
is the more attractive target because relays are bandwidth-bound and easy
to saturate.

**Mitigations in repo:** none direct.

**Mitigations available externally:**

- Cloud provider DDoS protection (DO, Hetzner, Vultr all offer basic
  L3/L4 mitigation by default).
- Put nginx behind Cloudflare (caveat: WebSocket-over-Cloudflare is fine
  but adds a hop and can trip up clients on flaky networks).
- Move TURN to a higher-bandwidth host if it gets popular enough to
  matter.

For Phase 0, accept the risk and move on. If usage grows to where DoS
attempts are realistic, the right move is "bigger VPS + provider DDoS"
not "build it in this repo."

### 3.5 Get RCE on the VPS via a software bug

The realistic surface is:

- Ubuntu apt packages (unattended-upgrades on by default — keep it on).
- nginx (Alpine in Docker mode, host package in native mode).
- coturn (Alpine in Docker mode, Ubuntu apt in native mode).
- Python websockets + aiohttp (signaling server's only deps).
- libssl behind all of the above.

None of these are unusual or under-audited; CVE response is generally
fast. The "delay" failure mode (apt upgrades stop running) is more
likely than a 0day.

**Mitigations in repo:**

- `inkternity-signaling.service` runs the signaling daemon as
  unprivileged user `inkternity` with `NoNewPrivileges`, `ProtectSystem=strict`,
  `ProtectHome=true`, `ProtectKernel*`, and a small `RestrictAddressFamilies`
  whitelist. RCE in signaling can't trivially pivot.
- The signaling Docker container runs as root inside the container (no
  USER directive). The container has no volume mounts. Limited blast
  radius but not minimal; worth tightening if you stay on Docker mode.

**Operational practice:** keep unattended-upgrades on. `apt list --upgradable`
once in a while. After a kernel upgrade, reboot — see `REBOOT.md` for the
verification checklist.

### 3.6 Read traffic in transit

WSS is TLS 1.2/1.3 (config in `nginx/inkternity-signaling.conf` and the
Docker `nginx.conf`). The signaling traffic is JSON envelopes for SDP +
ICE — useful to an attacker only insofar as it reveals who is currently
online and who is trying to talk to whom (a privacy leak, not a
confidentiality leak — WebRTC payload is separately encrypted).

**Mitigation in repo:** TLS 1.2+ minimum, modern cipher suites, HSTS
enabled, certbot-managed Let's Encrypt cert.

**Operational practice:** don't downgrade the cipher list. Don't enable
TLS 1.0/1.1 for any reason.

## 4. Credentials and where they live

| Credential | Where it's stored | Who knows it | Rotation |
|---|---|---|---|
| `TURN_SECRET` | `${SERVER_DIR}/.env`, chmod 600, owned by `inkternity`. Also baked into every shipped Inkternity binary's `default_p2p.json`. | Server operator + every Inkternity user. | `scripts/rotate_turn_secret.sh`. After rotation, re-ship Inkternity binaries; old ones lose TURN. |
| Let's Encrypt cert/key | `/etc/letsencrypt/{live,archive}/${DOMAIN_SIGNAL}/`. Group `root:root`, mode 600 on the key. | Server only. | Automatic — certbot.timer runs renewal twice daily; deploy hook reloads nginx + restarts coturn. |
| SSH key for the VPS | Your laptop. | You. | Rotate per your normal SSH hygiene. |

There are no application-level secrets in the signaling server — no
database password, no JWT signing key, no API key. The `inkternity` user
on the VPS has access to `.env` and the Let's Encrypt cert; nothing else
of value.

## 5. Logging and what to watch for

The default log level is `INFO`. Useful log lines:

| Log line | What it means |
|---|---|
| `connected id=<globalID> (active=N)` | A new WSS client connected. Normal. |
| `replacing prior connection for id=<globalID>` | Same globalID appeared twice. Normal during reconnect; suspicious if it keeps happening for one ID without that user reconnecting. |
| `rejected connection with empty path` | Someone hit the WSS endpoint without a globalID in the URL. Bots / scanners. Ignore unless volume spikes. |
| `dropping non-JSON message from id=<globalID>` | A connected client is sending garbage. Either a buggy fork, or an attacker probing. Watch for sustained volume. |
| `dropping message without 'id' field` | Same — protocol violation from a connected client. |

What you will NOT see in logs:

- Message contents. The relay deliberately doesn't log SDP, ICE
  candidates, or anything that would let you reconstruct what peers
  said to each other. Don't add such logging.
- Source IP addresses, by default. If you need them for abuse
  investigation, nginx logs the remote IP at the proxy layer (HTTP-level
  log); pair that with the globalID in the signaling log via timestamp.

## 6. Incident response, brief

If you suspect compromise:

1. **Suspected TURN secret leak:** `sudo ./scripts/rotate_turn_secret.sh`.
   New secret is in `.env` and live in coturn immediately. Plan an
   Inkternity rebuild + redistribute to push the new secret to clients.
2. **Suspected signaling abuse (DoS, junk traffic):** check
   `journalctl -u inkternity-signaling --since "10 minutes ago"` for the
   warning patterns above. If volume is real, add `limit_conn` / `limit_req`
   to the nginx server block; you do not need to redeploy the signaling
   server for this.
3. **Suspected VPS compromise (unexpected processes, login attempts):**
   treat as VPS-level incident, not a server-level one. Rotate
   credentials (TURN secret, SSH keys), rebuild the VPS from `vps_startup{,_native}.sh`
   on a fresh host, point DNS at the new IP. No application data needs
   restoring — there is none.
4. **Suspected Let's Encrypt cert leak:** revoke via
   `sudo certbot revoke --cert-name <DOMAIN_SIGNAL>`, then re-issue.
   Restart nginx and coturn.

## 7. What's deliberately out of scope

- **Per-session authentication on signaling.** Out of scope per Phase 0
  design (see `ARCHITECTURE.md` §8). Revisit at Phase 0.5.
- **Rate limiting on signaling.** Easy to add via nginx when needed; not
  worth the complexity until there's an actual abuser.
- **End-to-end audit logging.** The server intentionally does not record
  who talked to whom. If a future product change demands it, that's a
  design conversation, not a config change.
- **WebSocket message size limits.** Currently relies on `websockets`'
  default (1 MiB per message). Inkternity's SDP / ICE envelopes are <8
  KiB so this is fine; tighten in code if abuse warrants it.
