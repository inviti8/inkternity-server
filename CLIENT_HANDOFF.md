# Inkternity Server — Client Integration Handoff

Brief for whoever is wiring the Inkternity desktop client (the infinipaint
fork at `D:\repos\infinipaint` / `github.com/inviti8/inkternity`) to the
newly-live HEAVYMETA-owned signaling + TURN infrastructure. The server is
deployed, healthy, and waiting; the client side needs a config change, a
rebuild, and a smoke test before Phase 0 distribution can use it.

Read this once before touching `default_p2p.json` or `NetLibrary.cpp`.

---

## TL;DR

- **Signaling and TURN are live** at `signal.hvym.link` and `turn.hvym.link`
  on the existing hvym_tunnler VPS. Co-resident, native (systemd) deploy.
- The protocol the server speaks is libdatachannel's stock signaling
  shape, unchanged; the client needs no code changes for endpoint config.
- **Phase 0 token verification** (the `TokenVerifier.cpp` path) is the
  *next* piece of client-side work — separate from this endpoint swap and
  handled in `infinipaint/docs/design/DISTRIBUTION-PHASE0.md` §P0-C.

---

## 1. Live endpoints

| Service | Endpoint | Notes |
|---|---|---|
| Signaling (WSS) | `wss://signal.hvym.link` | libdatachannel connects via `wss://signal.hvym.link/<globalID>`. Stock libdatachannel signaling protocol. |
| TURN/STUN | `turn.hvym.link:3478` (TCP+UDP) | coturn, static long-term credentials. Username `inkternity`. |
| Health (HTTPS) | `https://signal.hvym.link/health` | Plain 200/`ok\n`. Useful for monitoring; not used by the desktop client. |
| TURNS (TLS-TURN) | *not enabled in Phase 0* | Plain TURN on 3478 is sufficient. TURNS on 5349 is a deferred follow-up — see `CERT_RENEWAL.md` §7 when needed. |

Cert validity: `signal.hvym.link` certificate is valid until **2026-08-09**.
Auto-renewal via certbot.timer + a deploy hook is wired up; no client-side
expiry handling required.

## 2. The config change

Edit `assets/data/config/default_p2p.json` in the infinipaint tree:

```json
{
    "signalingServer": "wss://signal.hvym.link",
    "stunList": [
        "stun.l.google.com:19302",
        "stun1.l.google.com:19302",
        "stun2.l.google.com:19302",
        "stun3.l.google.com:19302",
        "stun4.l.google.com:19302"
    ],
    "turnList": [
        {
            "url": "turn.hvym.link",
            "port": 3478,
            "username": "inkternity",
            "credential": "<TURN_SECRET>"
        }
    ]
}
```

`<TURN_SECRET>` is the 64-char hex string the server bootstrap printed
during deploy. It is also persisted at `/home/inkternity/inkternity-server/.env`
on the VPS (`TURN_SECRET=...`, mode 600, owned by user `inkternity`). Ask
the deploying operator if you don't have it; do *not* commit it to the
infinipaint repo's history if the repo is public — keep it in a local
build override or a private branch.

That's the only config change. `NetLibrary.cpp:46–54` already reads
`stunList` and `turnList` and feeds every entry to libdatachannel's
`rtc::Configuration::iceServers`; you do not need to modify the C++.

### Updating the baked-in endpoint

`default_p2p.json` is shipped baked into the app bundle; there is no
live-update mechanism for it. Endpoint changes reach installed users
only when they update to a new Inkternity binary. Plan release timing
accordingly if you ever migrate the live signaling/TURN to a new host.

## 3. The signaling protocol — what the server actually does

Same protocol as libdatachannel's reference signaling server; nothing
Inkternity-specific. Five lines of behavior:

1. Client opens `wss://signal.hvym.link/<globalID>` (40 hex chars).
2. Server takes the path component as the client's identity (`globalID`).
3. Client sends JSON `{"id": "<peer globalID>", "type": "...", ...}`.
4. Server forwards the message to the named peer's socket, rewriting `id`
   to the sender's globalID so the receiver knows who sent it.
5. Three message types: `offer`, `answer`, `candidate` (SDP + ICE).

Notable behavior:

- **No rooms, no auth, no persistence.** Anyone with the URL can connect.
  Trust lives in the desktop client (Phase 0 token check after WebRTC handshake).
- **Re-connect with same globalID wins.** If client A is already connected
  and another connection arrives claiming the same globalID, the old
  socket is closed with `1000 / superseded` and the new one takes its
  place. This is how libdatachannel recovers from network blips.
- **Missing target = silent drop.** Sending to an offline globalID drops
  the message. libdatachannel's WebRTC negotiation timeout handles the
  consequence.
- **Empty path = close.** Connecting to `wss://signal.hvym.link/` (no
  path) gets `1002 / missing client id in path`.

Reference implementation: `signaling/server.py` in this repo. ~130 lines
total. Read it if anything looks unexpected.

## 4. TURN: when it kicks in, how to rotate

WebRTC tries direct peer-to-peer first (using STUN servers to learn its
public address). TURN is the relay fallback when direct peering fails —
typically because one or both peers sit behind symmetric NAT (corporate
networks, some carrier-grade NATs). Most Inkternity sessions will never
touch TURN.

libdatachannel selects the relay path automatically based on the ICE
connectivity-check race. Client side doesn't choose; the WebRTC stack
does.

**Credential rotation:** if you ever need to roll the TURN secret (leaked,
team member offboarded, etc.):

```bash
ssh root@hvym.link "sudo /home/inkternity/inkternity-server/scripts/rotate_turn_secret.sh"
```

This regenerates the secret in `.env`, restarts coturn. After rotation,
every existing Inkternity binary loses TURN access (their baked-in
credential is now stale). The desktop app must be rebuilt + redistributed
with the new secret for users to keep falling back to TURN gracefully.
For Phase 0 scale, this is rare — leave it alone unless you have reason.

## 5. Phase 0 token verification — the next piece of client-side work

This is *not* server-side. The server is anonymous and stateless on
purpose (see `ARCHITECTURE.md` §1, §8). The token gate lives entirely in
the desktop app.

Quick recap of the design (from
`infinipaint/docs/design/DISTRIBUTION-PHASE0.md`):

1. HEAVYMETA portal issues a signed Stellar JWT to a subscriber after
   payment.
2. Subscriber joins an Inkternity canvas via WebRTC (using this server's
   signaling).
3. Once the data channel is up, the subscriber's app sends the token over
   the channel to the artist's app.
4. The **artist's app** (host) verifies the JWT signature against its
   local registered keys, accepts or rejects, and on accept allows the
   subscriber into the canvas.

The verifier lives at `infinipaint/src/Subscription/TokenVerifier.cpp` /
`.hpp`. There's a local minting tool at
`inkternity-server/scripts/dev_mint_token.py` that produces tokens in the
exact format the portal will produce in production — use it for unit
tests and local end-to-end runs without standing up the portal.

The signaling server doesn't see, doesn't store, and cannot validate
these tokens. By design.

## 6. Testing your changes

### Smoke test the server before touching anything client-side

From your laptop:

```bash
# TLS + HTTP /health
curl -v https://signal.hvym.link/health     # expect: ok

# WSS handshake (with websocat or any WS client)
websocat -v wss://signal.hvym.link/test_path
# expect: connection opens; sending any non-JSON message gets dropped silently
```

If both work, the server is fine and any failure later is client-side.

### End-to-end test with a real build

1. Edit `default_p2p.json` per §2 above.
2. `pip install -r inkternity-server/scripts/requirements.txt`
3. Mint a token locally:
   ```bash
   python inkternity-server/scripts/test_tunnel_client.py \
       --server wss://signal.hvym.link/<some-globalID>
   ```
   *(Use the existing `scripts/test_tunnel_client.py` in hvym_tunnler as
   a template — there is no equivalent for inkternity-server yet. The
   minimal version is just: open a WSS connection, send + receive a few
   messages, close cleanly.)*
4. Build Inkternity (two instances on two networks ideally — to actually
   exercise the WebRTC layer rather than localhost loopback).
5. Open the same canvas in both instances. If they connect and you see
   each other's drawing in real time, the full path works.

### Force TURN usage to test relay

By default WebRTC will use direct P2P or STUN if it can. To exercise
the TURN path specifically, you need to either:

- Block UDP between your two test machines (most easily by putting one
  behind a strict firewall), or
- Force libdatachannel to TURN-only by configuring `iceTransportPolicy = relay`
  in the `rtc::Configuration`. There's currently no flag for this in
  `default_p2p.json`; you'd need a one-line patch in `NetLibrary.cpp`
  for testing only. Don't ship.

If you see TURN credentials in coturn's logs (`journalctl -u coturn -f`
on the VPS) during your test session, the relay path is being exercised.

## 7. Health monitoring

### From outside

```bash
curl https://signal.hvym.link/health        # 200 ok
```

For a deeper TLS + WSS probe, see `REBOOT.md` §1 in this repo.

### From the VPS

```bash
ssh root@hvym.link
systemctl is-active inkternity-signaling coturn nginx
# expect: three "active" lines

journalctl -u inkternity-signaling -f
# expect: "connected id=..." / "disconnected id=..." lines as users join/leave
```

### From Inkternity itself

The client has no built-in health UI. The signaling WSS connection lives
in `NetLibrary::ws` (a `shared_ptr<rtc::WebSocket>`). If it disconnects
mid-session, libdatachannel's `onClosed` callback fires; existing P2P
channels keep working but no new peers can join. Worth surfacing as a
status indicator in a future Phase 0.5 polish.

## 8. Known issues and out-of-scope

- **`turn.hvym.link:443` TLS handshake fails.** Cosmetic. TURN doesn't
  speak HTTPS; nobody should ever hit this. The cert covering
  `turn.hvym.link` is stored under
  `/etc/letsencrypt/live/signal.hvym.link/` (single cert, two SANs), so
  the dynamic catch-all on :443 can't find a per-domain cert file. Fix
  when enabling TURNS.
- **No client-side reconnect logic for signaling.** If the server
  restarts, in-flight clients should reconnect automatically (libdatachannel
  does this), but verify in practice. If reconnects fail silently, that's
  a client bug, not a server one.
- **No metrics or per-session telemetry on the server.** Logs to
  journald only. If you want analytics on Phase 0 adoption, that has to
  come from the client (e.g., post-session telemetry to the portal) or
  from coturn's bandwidth counters.
- **No globalID-possession proof.** Anyone who knows a globalID can
  hijack signaling for that ID (close the legitimate socket, take over
  routing). WebRTC's DTLS fingerprint pinning means they can't actually
  join the data channel — but they can DoS the handshake. Phase 0.5
  follow-up.

None of these are blocking for Phase 0 launch.

## 9. References

- **In this repo (`inkternity-server`):**
  - `ARCHITECTURE.md` — full conceptual model, signaling protocol, data flow.
  - `DEPLOY.md` — how the server got onto the VPS, both modes.
  - `SECURITY.md` — threat model, what the server *is and isn't* trusted with.
  - `REBOOT.md` — post-reboot verification checklist.
  - `CERT_RENEWAL.md` — Let's Encrypt renewal mechanics, TURNS expansion.
  - `signaling/server.py` — the actual signaling daemon. Short and readable.
- **In the infinipaint tree:**
  - `assets/data/config/default_p2p.json` — the file you'll edit.
  - `include/Helpers/Networking/NetLibrary.hpp` / `.cpp` — WebRTC client.
  - `src/Subscription/TokenVerifier.cpp` / `.hpp` — Phase 0 token gate.
  - `docs/design/DISTRIBUTION-PHASE0.md` — design intent for the
    whole Phase 0 distribution model. Read §A (signaling + TURN) and §C
    (token verifier) before doing more than a config swap.
- **External:**
  - libdatachannel reference signaling protocol:
    https://github.com/paullouisageneau/libdatachannel
  - coturn:
    https://github.com/coturn/coturn

## 10. Open questions for the deploying operator

Before you ship a build pointing at the new endpoints, confirm with the
person who ran the bootstrap:

1. **TURN secret** — what's the value? (Lives in `/home/inkternity/inkternity-server/.env`
   on the VPS; needed for `default_p2p.json`.)

`signal.hvym.link` / `turn.hvym.link` are the canonical Phase 0 endpoints —
no further migration planned.
