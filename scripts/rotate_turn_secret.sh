#!/bin/bash
#
# Rotate the TURN long-term static credential.
#
# Usage:  sudo ./scripts/rotate_turn_secret.sh
#
# After this runs you MUST update default_p2p.json in any Inkternity build
# that references this server, or new clients won't be able to use TURN
# relays. STUN-only / direct-P2P clients are unaffected.

set -euo pipefail

SERVER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${SERVER_DIR}/.env"
CONF_FILE="${SERVER_DIR}/coturn/turnserver.conf"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env not found at ${ENV_FILE}"
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

NEW_SECRET=$(openssl rand -hex 32)
echo "New secret: ${NEW_SECRET}"

# Replace in .env
sed -i "s/^TURN_SECRET=.*/TURN_SECRET=${NEW_SECRET}/" "$ENV_FILE"

# Replace in turnserver.conf (rewriting from the marker is safer than
# pattern-matching the previous secret).
sed -i "s|^user=${TURN_USERNAME}:.*|user=${TURN_USERNAME}:${NEW_SECRET}|" "$CONF_FILE"

echo "Restarting coturn..."
cd "$SERVER_DIR"
docker compose restart coturn

echo "Done. Update Inkternity's default_p2p.json:"
echo '  "credential": "'"${NEW_SECRET}"'"'
