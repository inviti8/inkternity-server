# Inkternity Server

> Self-hosted WebRTC signaling and TURN infrastructure for the [Inkternity](https://github.com/inviti8/inkternity) live-collaboration and live-distribution model.

## What this repo is

The two stock pieces Inkternity needs to run a P2P session over WebRTC, packaged as a single deployable stack:

- **Signaling server** — a small Python WebSocket relay that brokers WebRTC offer/answer/ICE-candidate exchange between peers. Speaks the protocol Inkternity's bundled `libdatachannel` client expects.
- **TURN server** — stock [`coturn`](https://github.com/coturn/coturn). Used as a fallback when direct peer-to-peer NAT traversal fails.
- **nginx** — TLS termination for the WSS signaling endpoint (Let's Encrypt via certbot).

Deployed live for HEAVYMETA's Inkternity Phase 0 distribution model at `wss://signal.hvym.link` (signaling) and `turn.hvym.link:3478` (TURN). See `infinipaint/docs/design/DISTRIBUTION-PHASE0.md` §A.1 for the full design.

## What this repo is NOT

- It is not the Inkternity desktop app.
- It is not the Heavymeta Portal.
- It does not implement entitlement checks — the Phase 0 token gate lives in the Inkternity desktop app, not in the signaling server (the server stays anonymous and stateless).

## Quickstart

On a fresh Ubuntu 22.04 VPS with public IP and DNS pointed at it:

```bash
# 1. Set domain names in vps_startup.sh
nano scripts/vps_startup.sh   # edit DOMAIN_SIGNAL and DOMAIN_TURN

# 2. Run the bootstrap
sudo ./scripts/vps_startup.sh
```

The script installs Docker, nginx, certbot, clones this repo, generates a TURN secret, requests Let's Encrypt certs, and brings up the compose stack. Total time: ~5–10 minutes on a fresh VPS.

After it completes, point a fork of Inkternity at the new endpoints by editing its `assets/data/config/default_p2p.json`:

```json
{
    "signalingServer": "wss://signal.hvym.link",
    "stunList": ["stun.l.google.com:19302"],
    "turnList": [
        {
            "url": "turn.hvym.link",
            "port": 3478,
            "username": "<your TURN username>",
            "credential": "<your TURN secret>"
        }
    ]
}
```

See `DEPLOY.md` for full deployment notes (DNS prep, firewall rules, cert renewal, monitoring).

## Architecture

```
        Internet                          VPS (this repo)
            │
       :443 (WSS)        ┌──────────┐         ┌────────────────┐
            ────────────►│  nginx   │────────►│   signaling    │
                         │ (TLS,    │  :8000  │  (Python WS    │
                         │  proxy)  │         │   relay)       │
                         └──────────┘         └────────────────┘
            │
       :3478 (UDP/TCP)
       :49152-65535 (UDP)
            │            ┌──────────────────────────────┐
            ────────────►│           coturn             │
                         │  (TURN/STUN, host network)   │
                         └──────────────────────────────┘
```

- **Signaling**: client opens WSS to `wss://signal.hvym.link/<globalID>`. Server is a pure relay keyed by globalID; forwards JSON `{id, type, description}` (offer/answer) and `{id, type:"candidate", candidate, mid}` (ICE candidates) between peers. No auth, no rooms, no persistence.
- **TURN**: when direct WebRTC P2P can't punch through NAT, the client uses TURN to relay media via this server. Long-term static credentials configured per-deployment.

## Dev tooling

`scripts/dev_mint_token.py` issues valid Phase 0 access tokens locally without standing up the portal. Useful when implementing Inkternity's host-side verification (Stage 2 / P0-C work — see `infinipaint/docs/design/DISTRIBUTION-PHASE0.md`).

```bash
pip install -r scripts/requirements.txt

# After P0-C1 partial: Inkternity itself generates the app keypair on
# first run + writes inkternity_dev_keys.json. This script tops up the
# missing mock-portal fields (member keypair + canvas_id) and produces
# tokens. Use --state to load + save the same path:
python scripts/dev_mint_token.py \
    --state "$APPDATA/ErrorAtLine0/infinipaint/inkternity_dev_keys.json" \
    --gen-keys --expires-in 3600

# Subsequent mints (no key regen, same canvas):
python scripts/dev_mint_token.py \
    --state "$APPDATA/ErrorAtLine0/infinipaint/inkternity_dev_keys.json" \
    --expires-in 3600

# Verify a token's signature roundtrips against its claimed signer
python scripts/dev_mint_token.py --verify <token-from-stdout>
```

`--gen-keys` only fills MISSING fields, so it never clobbers Inkternity's locally-generated app keypair. The script mirrors the token format the portal's Stripe webhook will produce in production (sorted compact JSON payload + base64url ed25519 signature). Inkternity's host-side verifier accepts both Stellar G... and raw-hex pubkey formats; tokens minted by this script use Stellar form when `stellar-sdk` is installed.

## License

MIT. See `LICENSE`.
