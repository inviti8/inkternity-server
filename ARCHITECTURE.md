# Inkternity Server — Architecture

A reference for understanding how the pieces in this repo fit together with
the [Inkternity](https://github.com/inviti8/inkternity) desktop client (the
infinipaint-based fork) and what each piece is responsible for. Read this
once before reading `DEPLOY.md` or `SECURITY.md`; everything else assumes you
have this model in your head.

---

## 1. What this server is

A WebRTC trust-and-discovery backbone for peer-to-peer Inkternity sessions.
It is the bare minimum infrastructure required for two unrelated Inkternity
clients on the public internet to establish a direct WebRTC data channel
between each other.

There are exactly **two services** doing real work:

1. **Signaling server.** A WebSocket relay (~130 LoC of Python in
   `signaling/server.py`). When client A wants to talk to client B, A
   connects, names itself, and posts JSON messages addressed to B. The
   server forwards them. No persistence. No authentication. No rooms.
   The messages are SDP offers / answers / ICE candidates — the contents
   of which the server never inspects.

2. **TURN server.** Stock [coturn](https://github.com/coturn/coturn).
   Used as a fallback when WebRTC's NAT-traversal path can't find a direct
   route between peers. See §3 below for when and why this happens.

A third service — **nginx** — exists only as TLS terminator and reverse
proxy. It does not implement any application logic.

## 2. What this server is NOT

- **Not a session host.** Once two peers have exchanged SDP and ICE through
  the signaling server, they connect directly to each other over WebRTC.
  The signaling server's job is done. No drawing data, no waypoints, no
  presence — none of that touches this server.
- **Not an authentication server.** Anyone with the WSS URL can connect
  and send arbitrary messages. The Inkternity desktop app verifies Phase 0
  access tokens (Stellar-signed JWTs from the HEAVYMETA portal) entirely
  client-side, by inspecting the JWT after the WebRTC handshake completes.
  The signaling server stays anonymous and stateless on purpose — it holds
  zero secrets, has nothing to leak, and cannot be subverted into granting
  access it does not have.
- **Not the Heavymeta Portal.** Token issuance, Stripe webhooks, artist
  registration — none of that lives here. See `infinipaint/docs/design/
  DISTRIBUTION-PHASE0.md` for the broader Phase 0 picture.
- **Not the hvym_tunnler server.** hvym_tunnler is a separate stellar-keyed
  HTTP tunneling service. The two stacks can co-reside on one VPS (see
  `DEPLOY.md` §"Native mode"), but they share nothing except, optionally,
  one nginx instance.

## 3. STUN, TURN, and why you need both

WebRTC peers connect by exchanging *ICE candidates* — a list of (address,
port) pairs each thinks it can be reached on. The peer then races every
combination of candidates and uses whichever pair establishes a connection
first.

Most candidates a client gathers locally are useless to a remote peer
(`192.168.x.x`, `10.x.x.x`, IPv6 link-local, etc.). Two extra mechanisms
fix that:

| Mechanism | What it does | Cost to operator |
|---|---|---|
| **STUN** | Client asks "what does my public IP/port look like from outside?" and adds that pair to its candidate list. Used in ~80–90% of sessions. | Trivial — stateless single-packet exchange. Public servers (`stun.l.google.com:19302`) are fine for free use. |
| **TURN** | When no candidate pair works directly (typically: one or both peers behind symmetric NAT or restrictive firewalls), each peer connects *to the TURN server* and the TURN server relays packets between them. Used in ~10–20% of sessions. | Bandwidth-bound. Every byte of every relayed session passes through your VPS. |

Inkternity's client (libdatachannel) handles all of this automatically when
you give it the STUN and TURN entries from `default_p2p.json`. STUN-only
gets you a working app for most users; without TURN, anyone behind a
symmetric NAT silently fails to connect to anyone else. For a paid product,
that's not an acceptable tradeoff — so this stack ships with coturn even
though most sessions will never use it.

**TURNS** (TURN over TLS on port 5349) is a further-fallback some networks
require because they block all UDP outright. The shipped `turnserver.conf`
leaves TURNS commented out; enable it if/when you see clients reporting
"can't reach TURN" on restrictive networks (corporate / mobile carriers).

## 4. The signaling protocol on the wire

The signaling server speaks exactly the protocol Inkternity's bundled
libdatachannel reference client expects — defined by libdatachannel, not
invented here.

**Connection:**

```
wss://signal.heavymeta.art/<globalID>
```

The URL path component IS the connecting client's globalID — a 40-character
identifier the client generated locally (see `infinipaint/include/Helpers/
Networking/NetLibrary.hpp:36`). The server never validates the format; it
just uses the path string as the routing key.

**Messages:** UTF-8 JSON, three shapes:

```json
{"id": "<peer globalID>", "type": "offer",     "description": "<SDP>"}
{"id": "<peer globalID>", "type": "answer",    "description": "<SDP>"}
{"id": "<peer globalID>", "type": "candidate", "candidate": "<ICE>", "mid": "<sdp-mid>"}
```

**Server behavior:** when A sends `{"id": "B", ...}`, the server looks up
the currently-connected socket for `B`, rewrites the `id` field to `A` so
B knows where the message came from, and forwards the JSON unchanged. If
B is not online, the message is dropped silently — the originating peer
discovers this via WebRTC's negotiation timeout.

**Edge cases:**

- If A connects with the same globalID a second time, the old connection
  is closed (`code=1000, reason="superseded"`) and the new one wins. This
  is how Inkternity recovers from a network blip without rejecting the
  reconnect.
- Empty path → connection refused with `code=1002`.
- Non-JSON or `id`-less messages → dropped, logged at WARNING.

That's the entire protocol. `signaling/server.py` is ~130 lines because
there's nothing else to do.

## 5. Health endpoint

The aiohttp listener on `LISTEN_PORT + 1` (8001 in Docker mode, 8003 in
native mode) serves a single endpoint:

```
GET /health  →  200 OK, body "ok\n"
```

nginx proxies `signal.heavymeta.art/health` to this listener so external
monitoring (uptime checks, load balancers, the hvym_tunnler co-resident
deploy script's pre-flight) can hit it over HTTPS without speaking
WebSocket. There is deliberately no `/health` route on the WebSocket
listener — opening a TCP connection to port 8000 with an HTTP GET fails the
`Upgrade` check, which is the correct behavior for a WS-only port but
makes monitoring noisy. Hence the sibling aiohttp server.

## 6. Deployment shapes

The repo supports two operationally distinct shapes; pick one per VPS.

| | Docker mode | Native mode |
|---|---|---|
| Defined in | `docker-compose.yml`, `scripts/vps_startup.sh` | `systemd/*.service`, `nginx/inkternity-signaling.conf`, `scripts/vps_startup_native.sh` |
| signaling runs as | Python in `inkternity-signaling` container | systemd-managed Python venv on the host |
| coturn runs as | `coturn/coturn:latest` container, host networking | Ubuntu apt `coturn` package, systemd |
| nginx runs as | `nginx:alpine` container, owns :80/:443 | host nginx, owns :80/:443 |
| Co-resides with hvym_tunnler | no (nginx :80/:443 collision) | yes (shares the host nginx) |
| Best for | Single-tenant VPS dedicated to Inkternity | VPS already running hvym_tunnler or another nginx-fronted service |

Both modes produce functionally identical externals: WSS on
`signal.heavymeta.art:443`, TURN on `turn.heavymeta.art:3478`, the same
TURN secret in `.env`, the same Let's Encrypt certs. Switching between
them is non-trivial (different process supervisors, different cert
paths in nginx config) but supported.

See `DEPLOY.md` for the operational walkthrough of both.

## 7. Data flow — full session, end to end

For someone reading this and trying to visualize what actually happens
when an Inkternity user shares a canvas:

```
   Artist (host)                                       Subscriber (peer)
   ─────────────                                       ─────────────────
   1. starts Inkternity, opens a canvas.
   2. NetLibrary::init() reads default_p2p.json,
      generates globalID (40 hex chars).
   3. opens WSS to signal.heavymeta.art/<artist-globalID>.
                                                   4. starts Inkternity, joins lobby.
                                                   5. opens WSS to signal.heavymeta.art/<sub-globalID>.
                                                   6. sends {id: artist-globalID, type: "offer", description: <SDP>}.
   7. server forwards to artist's socket
      with id rewritten to <sub-globalID>.
   8. accepts offer, replies
      {id: sub-globalID, type: "answer", description: <SDP>}.
                                                   9. server forwards to subscriber.
  10-N. both sides exchange "candidate"
        messages via the server as ICE gathers.
                                                  10-N. same.
  ──────────────────────  WebRTC connectivity check race  ──────────────────────
                                                       (uses STUN servers to learn
                                                        public addresses; falls
                                                        back to TURN if direct
                                                        peering fails)
  N+1. data channel established peer-to-peer.
       Inkternity host-side token verifier
       (TokenVerifier.cpp) inspects the
       subscriber's signed JWT now flowing
       over the channel. Accept / reject.
  N+2. drawing data, waypoints, presence,
       resources — all flow direct peer-to-peer.
       Signaling server's job is done.
```

The signaling server is involved only in steps 7–10. The TURN server is
involved only if step N's connectivity check race exhausts direct
candidates and falls back to relay. Everything substantive — the actual
canvas work — happens between the two clients directly.

This is what makes the server cheap to run: it touches every session, but
only briefly. A 1 vCPU / 1–2 GiB VPS handles hundreds of concurrent
sessions trivially for signaling; coturn scales with bandwidth.

## 8. Why the server is stateless

A common ask is "shouldn't there be rooms / lobbies / auth on the
signaling server?" There shouldn't be, and the reason matters:

- **The signaling server holds zero session-critical information.** SDP
  and ICE candidates expire seconds after they're exchanged; they're not
  reusable, not replayable in any useful way.
- **The Phase 0 trust model is end-to-end client-side.** The artist's app
  verifies the subscriber's signed JWT directly, after the WebRTC channel
  is up. A compromised signaling server cannot mint tokens, cannot
  impersonate either peer, and cannot decrypt traffic (WebRTC payload is
  DTLS-SRTP encrypted between peers).
- **Statelessness is a security property.** A stateful server that knew
  who was talking to whom would be a privacy target. This one isn't.
- **It is also an availability property.** Restarts are free. No state
  to migrate, no upgrade dance.

The Inkternity desktop app, not the server, is responsible for *who can
join what*. The server's only job is *carry these JSON envelopes from A
to B*.

## 9. Failure modes and what each costs

| If this breaks… | …then… |
|---|---|
| Signaling server goes down | New sessions can't form. In-flight sessions are unaffected (already past the WebRTC handshake). |
| coturn goes down | New sessions whose peers need TURN can't form. STUN-direct sessions are unaffected. Existing relayed sessions drop. |
| nginx goes down | Both above, simultaneously, plus health check fails. |
| TURN secret is leaked | Anyone can use your TURN bandwidth. Rotate via `scripts/rotate_turn_secret.sh` and re-ship Inkternity binaries. Until you rotate, no security exposure beyond bandwidth abuse — TURN can't see encrypted payloads. |
| Let's Encrypt cert expires | WSS handshake fails. Certbot's systemd timer + deploy hook prevents this from happening unattended. See `CERT_RENEWAL.md`. |
| Whole VPS dies | Stand up a fresh VPS, re-run `vps_startup{,_native}.sh`, point DNS at the new IP, wait for propagation. Total downtime: tens of minutes. No data to recover. |
