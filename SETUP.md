# Inkternity Server — Local Setup

For developers who want to run signaling + (optionally) coturn locally
without standing up a VPS, and for production operators who want to
verify their changes before pushing. If you're deploying to a real VPS,
read `DEPLOY.md` instead; this doc covers `localhost` only.

There are three modes you might want, in increasing order of fidelity to
production:

1. **Direct Python** — fastest iteration; bypasses Docker entirely.
   Suitable when you're hacking on `signaling/server.py`.
2. **Docker dev compose** — runs the signaling container only, exposed
   on `localhost:8000`. Production-shape minus nginx/coturn. Use when
   you want to test the actual image you'll ship.
3. **Full prod-shape locally** — the whole compose stack including
   nginx + coturn. Almost never useful (no Let's Encrypt cert, TURN
   can't relay over loopback). Documented for completeness only.

---

## Prerequisites

- Python 3.10+ (3.11 recommended; signaling Dockerfile uses 3.11-slim).
- Docker 20.10+ with Compose plugin (only for modes 2 and 3).
- Git.
- For the Phase 0 token tooling: `pip install -r scripts/requirements.txt`
  (`stellar-sdk`, etc.).

System resources: signaling is trivial (~50 MB RSS, no measurable CPU
when idle). Docker image build pulls ~150 MB. coturn idle is ~30 MB.

## 1. Direct Python — fastest iteration

Best when you're touching `signaling/server.py` and want a tight
edit-run-test loop without rebuilding a Docker image each time.

```bash
git clone https://github.com/inviti8/inkternity-server.git
cd inkternity-server

# Create a venv and install signaling's two dependencies.
python -m venv .venv
source .venv/bin/activate         # (Windows: .venv\Scripts\Activate.ps1)
pip install -r signaling/requirements.txt

# Run it.
LOG_LEVEL=DEBUG python signaling/server.py
```

Output you should see immediately:

```
YYYY-MM-DD HH:MM:SS [INFO] health listener on 0.0.0.0:8001
YYYY-MM-DD HH:MM:SS [INFO] signaling listening on 0.0.0.0:8000
```

In another shell, smoke-test the health endpoint:

```bash
curl http://localhost:8001/health
# expect: ok
```

Smoke-test the WS endpoint with [`websocat`](https://github.com/vi/websocat)
or any WebSocket client:

```bash
websocat ws://localhost:8000/abc
# server logs: connected id=abc (active=1)
# type: {"id": "xyz", "type": "candidate", "candidate": "test", "mid": "0"}
# server forwards to xyz if it's connected; otherwise drops silently
```

Environment variables the server respects:

| Var | Default | Purpose |
|---|---|---|
| `LOG_LEVEL` | `INFO` | Standard Python logging level: `DEBUG`, `INFO`, `WARNING`, `ERROR`. |
| `LISTEN_HOST` | `0.0.0.0` | Bind address. Set to `127.0.0.1` to keep it off the LAN. |
| `LISTEN_PORT` | `8000` | WS port. Health listener uses `LISTEN_PORT + 1`. |

Hot reload: there isn't one built in. `Ctrl-C` and re-run after edits;
the daemon starts in ~50 ms.

## 2. Docker dev compose — production-shape, single service

Same image you'll ship to production, exposed on the loopback for local
testing. Uses `docker-compose.dev.yml` as an overlay that:

- Binds `signaling` directly to `127.0.0.1:8000` (and `:8001`).
- Skips `nginx` and `coturn` via the `prod` profile — locally there are
  no Let's Encrypt certs to mount, and TURN can't usefully relay over
  loopback anyway.

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml build signaling
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d signaling

# Smoke test
curl http://localhost:8001/health
# expect: ok

# Tail logs
docker compose logs -f signaling

# Stop
docker compose down
```

Inkternity's local `default_p2p.json` (or a per-build override) should
point at `ws://localhost:8000` (note: `ws`, not `wss`, because there's
no nginx in this mode):

```json
{
    "signalingServer": "ws://localhost:8000",
    "stunList": ["stun.l.google.com:19302"],
    "turnList": []
}
```

## 3. Full prod-shape locally — for completeness

Brings up nginx + coturn alongside signaling. Requires you to either:

- Have `/etc/letsencrypt/live/<domain>/` populated locally (you usually
  won't), or
- Edit `nginx/nginx.conf` to drop the TLS block before running.

In practice, mode 3 is only useful as a final shake-out before pushing
to a real VPS, and most operators just push to a staging VPS instead.

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml --profile prod up -d
```

## 4. Phase 0 token tooling

`scripts/dev_mint_token.py` issues valid Phase 0 access tokens locally
without standing up the HEAVYMETA portal. Useful when you're implementing
or testing Inkternity's host-side verification path (see
`infinipaint/docs/design/DISTRIBUTION-PHASE0.md` §P0-C).

```bash
pip install -r scripts/requirements.txt

# Mint a token, persisting any missing keys into Inkternity's state file
# (the same path Inkternity itself reads on first run):
python scripts/dev_mint_token.py \
    --state "$APPDATA/ErrorAtLine0/infinipaint/inkternity_dev_keys.json" \
    --gen-keys --expires-in 3600

# Subsequent mints — same canvas, no key regen:
python scripts/dev_mint_token.py \
    --state "$APPDATA/ErrorAtLine0/infinipaint/inkternity_dev_keys.json" \
    --expires-in 3600

# Verify a token's signature roundtrips against its claimed signer:
python scripts/dev_mint_token.py --verify <token-from-stdout>
```

`--gen-keys` only fills missing fields, so it never clobbers Inkternity's
locally-generated app keypair. The script mirrors the token format the
portal's Stripe webhook will produce in production (sorted compact JSON
payload + base64url ed25519 signature). Inkternity's host-side verifier
accepts both Stellar `G…` and raw-hex pubkey formats; tokens minted by
this script use Stellar form when `stellar-sdk` is installed.

## 5. Editing nginx or coturn locally

Both configs use templated placeholders that the deploy script substitutes:

- `nginx/nginx.conf` and `nginx/inkternity-signaling.conf` use
  `signal.hvym.link` as the sentinel domain.
- `coturn/turnserver.conf` uses `__TURN_USERNAME__`, `__TURN_SECRET__`,
  `__TURN_REALM__`.

When editing, leave the sentinels in place — the deploy scripts
`sed`-substitute them at install time (the docker script in-place; the
native script into a destination copy, leaving the repo file pristine).

## 6. Project layout

```
inkternity-server/
├── ARCHITECTURE.md            # how the pieces fit together
├── DEPLOY.md                  # VPS deployment, both modes
├── REBOOT.md                  # post-reboot verification checklist
├── CERT_RENEWAL.md            # Let's Encrypt renewal mechanics
├── SECURITY.md                # threat model + operational practice
├── SETUP.md                   # this file
├── README.md                  # one-screen project overview
│
├── docker-compose.yml         # production-shape: signaling + nginx + coturn
├── docker-compose.dev.yml     # dev overlay: just signaling on loopback
│
├── signaling/
│   ├── server.py              # the entire signaling daemon (~130 LoC)
│   ├── requirements.txt       # websockets + aiohttp
│   └── Dockerfile             # python:3.11-slim + the above
│
├── nginx/
│   ├── nginx.conf             # config baked into the nginx:alpine container
│   └── inkternity-signaling.conf  # host-nginx drop-in for native mode
│
├── coturn/
│   └── turnserver.conf        # coturn config with __TURN_*__ placeholders
│
├── systemd/
│   └── inkternity-signaling.service   # native-mode signaling daemon unit
│
└── scripts/
    ├── vps_startup.sh         # Docker-mode VPS bootstrap (apt + docker + compose)
    ├── vps_startup_native.sh  # Native-mode bootstrap (apt + systemd + host nginx)
    ├── rotate_turn_secret.sh  # regenerate TURN_SECRET, restart coturn
    ├── dev_mint_token.py      # Phase 0 token mock for host-side verifier tests
    └── requirements.txt       # extras for dev_mint_token.py
```

Everything in `signaling/`, `nginx/`, and `coturn/` is small enough to
read top-to-bottom in an afternoon. The repo has no hidden complexity.

## 7. Running tests

There is no test suite at present. The signaling protocol is small and
behavior is exercised end-to-end every time you join an Inkternity canvas;
unit tests have not been worth the maintenance burden.

If you add complex behavior (rate limiting, message size enforcement,
auth), add tests in `signaling/tests/` and wire up pytest. Until then,
"smoke test with a real Inkternity build pointed at `ws://localhost:8000`"
is the recommended verification.
