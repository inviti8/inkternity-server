#!/usr/bin/env python3
"""
Phase 0 dev token mint helper.

Generates valid Inkternity access tokens for development/testing
without standing up the portal. Mirrors the format the portal's
Stripe webhook handler will produce in production
(see DISTRIBUTION-PHASE0.md §5).

Usage examples:

  # Generate a fresh keypair set + canvas_id + token, save state for reuse.
  python dev_mint_token.py --gen-keys --save-state state.json

  # Mint another token using the saved state (same keys, same canvas).
  python dev_mint_token.py --load-state state.json

  # Mint with a 1-hour expiry.
  python dev_mint_token.py --load-state state.json --expires-in 3600

  # Verify a token roundtrips against its own claimed signer.
  python dev_mint_token.py --verify <token>

Token format (matches DISTRIBUTION-PHASE0.md §5):

  <base64url(64-byte ed25519 signature)> "." <base64url(json_payload)>

Payload (single-letter keys, sorted, compact):

  {
    "a":   "GAB..." or hex,    artist member pubkey (signer)
    "c":   "uuid",             canvas id
    "e":   1761686400,         expires_at unix (omitted = no expiry)
    "i":   1730150400,         issued_at unix
    "k":   "abcd...",          artist Inkternity app pubkey (hex)
    "sub": "sha256(email)"     subscriber identity hash for audit
  }

Inkternity-side verification (must match all):
  ed25519_verify(payload.a, signature, payload_bytes)
  payload.a == host's own member pubkey
  payload.k == host's own app pubkey
  payload.c == host's open canvas_id
  payload.e > now() if set
"""

import argparse
import base64
import hashlib
import json
import os
import sys
import time
import uuid

try:
    import nacl.signing
    import nacl.encoding
    import nacl.exceptions
except ImportError:
    print("ERROR: pynacl not installed. Run: pip install -r scripts/requirements.txt", file=sys.stderr)
    sys.exit(1)

try:
    from stellar_sdk import Keypair as StellarKeypair
    HAS_STELLAR = True
except ImportError:
    HAS_STELLAR = False


def b64u(b: bytes) -> str:
    """URL-safe base64 without padding."""
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode("ascii")


def b64u_decode(s: str) -> bytes:
    """URL-safe base64 with padding restored."""
    pad = "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s + pad)


def gen_member_keypair() -> tuple[str, str]:
    """Stellar Ed25519 member keypair. Returns (secret_seed, public_address).

    Uses Stellar S.../G... encoding when stellar_sdk is available so dev
    tokens look like the production form. Falls back to hex.
    """
    if HAS_STELLAR:
        kp = StellarKeypair.random()
        return kp.secret, kp.public_key
    sk = nacl.signing.SigningKey.generate()
    return (sk.encode(nacl.encoding.HexEncoder).decode(),
            sk.verify_key.encode(nacl.encoding.HexEncoder).decode())


def gen_app_keypair() -> tuple[str, str]:
    """Ed25519 keypair for the artist's Inkternity app install. Returns (secret_hex, public_hex)."""
    sk = nacl.signing.SigningKey.generate()
    return (sk.encode(nacl.encoding.HexEncoder).decode(),
            sk.verify_key.encode(nacl.encoding.HexEncoder).decode())


def signing_key_from_member_secret(secret: str) -> nacl.signing.SigningKey:
    """Get a libsodium SigningKey from a member secret in either Stellar S... or raw-hex form."""
    if secret.startswith("S") and HAS_STELLAR:
        seed = StellarKeypair.from_secret(secret).raw_secret_key()
        return nacl.signing.SigningKey(bytes(seed))
    return nacl.signing.SigningKey(secret, encoder=nacl.encoding.HexEncoder)


def verify_key_from_member_pub(pub: str) -> nacl.signing.VerifyKey:
    """Get a libsodium VerifyKey from a member pubkey in either Stellar G... or raw-hex form."""
    if pub.startswith("G") and HAS_STELLAR:
        raw = StellarKeypair.from_public_key(pub).raw_public_key()
        return nacl.signing.VerifyKey(bytes(raw))
    return nacl.signing.VerifyKey(pub, encoder=nacl.encoding.HexEncoder)


def mint(member_secret: str, member_pub: str, app_pub: str,
         canvas_id: str, subscriber_email: str | None,
         expires_in: int | None) -> str:
    """Build, sign, and serialize a Phase 0 token. Returns the wire-format token string."""
    now = int(time.time())
    payload = {
        "a": member_pub,
        "c": canvas_id,
        "i": now,
        "k": app_pub,
    }
    if expires_in is not None:
        payload["e"] = now + expires_in
    if subscriber_email:
        payload["sub"] = hashlib.sha256(subscriber_email.encode()).hexdigest()

    # Sorted compact JSON — verifier reconstructs the same bytes.
    payload_bytes = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
    sk = signing_key_from_member_secret(member_secret)
    signature = sk.sign(payload_bytes).signature

    return f"{b64u(signature)}.{b64u(payload_bytes)}"


def verify(token: str) -> dict:
    """Verify token signature roundtrips against its own claimed signer.

    This proves the token is internally consistent — exactly what the
    Inkternity host's first verification check does. The Inkternity
    host then ALSO checks payload.a == own_member_pubkey and the other
    bindings; this script doesn't have access to those.
    """
    if "." not in token:
        raise ValueError("invalid token: missing '.' separator")
    sig_b64, payload_b64 = token.split(".", 1)
    signature = b64u_decode(sig_b64)
    payload_bytes = b64u_decode(payload_b64)
    payload = json.loads(payload_bytes)

    vk = verify_key_from_member_pub(payload["a"])
    vk.verify(payload_bytes, signature)  # raises BadSignatureError on mismatch
    return payload


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    parser.add_argument("--gen-keys", action="store_true",
                        help="Generate fresh artist member + app keypairs.")
    parser.add_argument("--save-state", metavar="PATH",
                        help="Save keypairs + canvas_id to PATH for later reuse.")
    parser.add_argument("--load-state", metavar="PATH",
                        help="Load keypairs + canvas_id from PATH.")

    parser.add_argument("--member-secret", help="Override: artist member secret (Stellar S... or hex).")
    parser.add_argument("--member-pub",    help="Override: artist member pubkey (Stellar G... or hex).")
    parser.add_argument("--app-pub",       help="Override: artist Inkternity app pubkey (hex).")
    parser.add_argument("--canvas-id",     help="Canvas UUID (auto-generated when --gen-keys).")

    parser.add_argument("--subscriber", default="dev@example.com",
                        help="Subscriber email (hashed into payload.sub). Default: dev@example.com.")
    parser.add_argument("--expires-in", type=int, default=None,
                        help="Token expires in N seconds from now. Default: no expiry.")

    parser.add_argument("--verify", metavar="TOKEN",
                        help="Verify TOKEN's signature against its own claimed signer.")

    args = parser.parse_args()

    if args.verify:
        try:
            payload = verify(args.verify)
        except nacl.exceptions.BadSignatureError:
            print("INVALID: signature mismatch", file=sys.stderr)
            sys.exit(2)
        except (ValueError, KeyError) as e:
            print(f"INVALID: {e}", file=sys.stderr)
            sys.exit(2)
        print("OK — signature verifies against payload.a")
        print(json.dumps(payload, indent=2, sort_keys=True))
        return

    state: dict[str, str] = {}
    if args.load_state and os.path.exists(args.load_state):
        with open(args.load_state) as f:
            state = json.load(f)

    if args.gen_keys:
        state["member_secret"], state["member_pub"] = gen_member_keypair()
        state["app_secret"],    state["app_pub"]    = gen_app_keypair()
        if "canvas_id" not in state:
            state["canvas_id"] = str(uuid.uuid4())

    # Explicit overrides
    if args.member_secret: state["member_secret"] = args.member_secret
    if args.member_pub:    state["member_pub"]    = args.member_pub
    if args.app_pub:       state["app_pub"]       = args.app_pub
    if args.canvas_id:     state["canvas_id"]     = args.canvas_id

    missing = [k for k in ("member_secret", "member_pub", "app_pub", "canvas_id")
               if not state.get(k)]
    if missing:
        print(f"ERROR: missing required: {', '.join(missing)}.", file=sys.stderr)
        print("Pass --gen-keys, or --load-state, or set them explicitly.", file=sys.stderr)
        sys.exit(2)

    if args.save_state:
        with open(args.save_state, "w") as f:
            json.dump(state, f, indent=2)
        print(f"State saved to {args.save_state}", file=sys.stderr)

    token = mint(
        state["member_secret"], state["member_pub"], state["app_pub"],
        state["canvas_id"], args.subscriber, args.expires_in,
    )

    expiry_str = ("never" if args.expires_in is None
                  else f"{int(time.time()) + args.expires_in} (in {args.expires_in}s)")

    print()
    print("=== Mint complete ===")
    print(f"Artist member pubkey  (a):   {state['member_pub']}")
    print(f"Artist app pubkey     (k):   {state['app_pub']}")
    print(f"Canvas id             (c):   {state['canvas_id']}")
    print(f"Expires at:                  {expiry_str}")
    print(f"Subscriber:                  {args.subscriber}")
    print()
    print("=== Token (paste into Inkternity Connect dialog) ===")
    print(token)
    print()


if __name__ == "__main__":
    main()
