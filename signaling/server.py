"""
Inkternity WebRTC signaling server.

Speaks the protocol Inkternity's bundled libdatachannel client expects:
- Each client opens a WSS connection to /<globalID>.
- Each client identifies itself by the path component (its globalID).
- Messages are JSON. Three shapes:
    {"id": "<peer globalID>", "type": "offer",     "description": "<SDP>"}
    {"id": "<peer globalID>", "type": "answer",    "description": "<SDP>"}
    {"id": "<peer globalID>", "type": "candidate", "candidate": "<ICE>", "mid": "<sdp-mid>"}
- The server's job: when client A sends a message addressed to "id": "B",
  forward it (with "id" rewritten to A's globalID) to whichever WebSocket B
  is currently using.
- No auth, no rooms, no persistence. The signaling server holds zero
  critical information; sessions are established peer-to-peer over WebRTC
  immediately after the SDP exchange completes.

Health endpoint: GET /health -> 200 OK on a separate aiohttp listener.
"""

import asyncio
import json
import logging
import os
from typing import Dict

import websockets
from aiohttp import web

LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 8000

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("signaling")

# Maps globalID -> active WebSocket. One entry per connected client.
peers: Dict[str, websockets.WebSocketServerProtocol] = {}


async def relay(ws: websockets.WebSocketServerProtocol, path: str) -> None:
    # Path is /<globalID>; strip the leading slash.
    sender_id = path.lstrip("/")
    if not sender_id:
        log.warning("rejected connection with empty path")
        await ws.close(code=1002, reason="missing client id in path")
        return

    # Replace any prior connection from this same id; the new one wins.
    prior = peers.get(sender_id)
    if prior is not None:
        log.info("replacing prior connection for id=%s", sender_id)
        try:
            await prior.close(code=1000, reason="superseded")
        except Exception:
            pass
    peers[sender_id] = ws
    log.info("connected id=%s (active=%d)", sender_id, len(peers))

    try:
        async for raw in ws:
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                log.warning("dropping non-JSON message from id=%s", sender_id)
                continue

            target_id = msg.get("id")
            if not isinstance(target_id, str):
                log.warning("dropping message without 'id' field from id=%s", sender_id)
                continue

            target_ws = peers.get(target_id)
            if target_ws is None:
                # Target offline; silently drop. The originating peer
                # handles this via WebRTC negotiation timeout.
                log.debug("drop msg from %s -> %s (offline)", sender_id, target_id)
                continue

            # Rewrite the "id" field so the recipient sees who sent it,
            # not who it was addressed to.
            forwarded = dict(msg)
            forwarded["id"] = sender_id
            try:
                await target_ws.send(json.dumps(forwarded))
            except websockets.ConnectionClosed:
                log.debug("target %s closed during forward", target_id)
    finally:
        # Only remove if we're still the registered socket; a replacing
        # connection may have already taken our slot.
        if peers.get(sender_id) is ws:
            del peers[sender_id]
        log.info("disconnected id=%s (active=%d)", sender_id, len(peers))


async def health_handler(_request: web.Request) -> web.Response:
    return web.Response(text="ok\n", status=200)


async def start_health_server() -> None:
    app = web.Application()
    app.router.add_get("/health", health_handler)
    runner = web.AppRunner(app)
    await runner.setup()
    # Health endpoint shares port 8000 with the signaling WebSocket via
    # path-based routing in nginx; the nginx config sends /health to
    # this aiohttp listener and everything else to the websockets server.
    # For simplicity we run aiohttp on a sibling port that nginx targets
    # alongside the WS upgrade, but in this single-binary mode we let
    # nginx upgrade-route /<globalID> to ws and /health to ourselves.
    site = web.TCPSite(runner, LISTEN_HOST, LISTEN_PORT + 1)
    await site.start()
    log.info("health listener on %s:%d", LISTEN_HOST, LISTEN_PORT + 1)


async def main() -> None:
    await start_health_server()
    log.info("signaling listening on %s:%d", LISTEN_HOST, LISTEN_PORT)
    async with websockets.serve(relay, LISTEN_HOST, LISTEN_PORT):
        await asyncio.Future()  # run forever


if __name__ == "__main__":
    asyncio.run(main())
