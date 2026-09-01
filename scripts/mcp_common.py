"""Shared MCP client for the MishMail helper scripts."""

import json
import os
import sys
import threading
import urllib.request
from pathlib import Path

DISCOVERY = (Path.home() / "Library/Containers/dev.ronboger.MishMail/Data"
             / "Library/Application Support/MishMail/mcp.json")
# Preferred: a copy of the token outside the app container. Reading the
# container itself needs Full Disk Access, and on a Mac without it the read
# BLOCKS on a TCC prompt rather than failing — so try this first.
TOKEN_FILE = Path.home() / ".config/mishmail/mcp-token"
DEFAULT_PORT = "41888"


# urllib consults macOS system proxy settings, so a VPN or PAC file can make
# even a 127.0.0.1 request hang. The MCP server is always loopback — never
# proxy it.
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def post_json(url, payload, headers=None, timeout=180):
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", **(headers or {})})
    with _OPENER.open(req, timeout=timeout) as r:
        return json.loads(r.read())


class MCP:
    """Minimal JSON-RPC client against the in-app MishMail MCP server."""

    def __init__(self, discovery=DISCOVERY):
        # Env wins over the discovery file: a launchd agent (or any process
        # without Full Disk Access) cannot read another app's sandbox
        # container, but the port is fixed and the token is stable, so both
        # can simply be supplied.
        token = os.environ.get("MISHMAIL_MCP_TOKEN")
        port = os.environ.get("MISHMAIL_MCP_PORT", DEFAULT_PORT)
        if not token and TOKEN_FILE.exists():
            token = TOKEN_FILE.read_text().strip() or None
        cfg = None
        if Path(discovery).exists():
            try:
                cfg = json.loads(Path(discovery).read_text())
            except PermissionError:
                cfg = None
            except json.JSONDecodeError:
                cfg = None
        if cfg and cfg.get("port") is not None and "MISHMAIL_MCP_PORT" not in os.environ:
            port = cfg["port"]
        if not token and cfg and cfg.get("token"):
            # Legacy mcp.json that still stored the bearer token.
            token = cfg["token"]
        if not token:
            sys.exit("MISHMAIL_MCP_TOKEN is unset, ~/.config/mishmail/mcp-token "
                     "is missing, and mcp.json has no token. Copy the token "
                     "from Settings → AI → MCP.")
        self.url = f"http://127.0.0.1:{port}/mcp"
        self.headers = {"Authorization": f"Bearer {token}"}
        self._id = 0
        # Callers may summarize concurrently (--jobs); keep ids unique.
        self._lock = threading.Lock()

    def call(self, tool, args=None):
        with self._lock:
            self._id += 1
            rpc_id = self._id
        resp = post_json(self.url, {
            "jsonrpc": "2.0", "id": rpc_id, "method": "tools/call",
            "params": {"name": tool, "arguments": args or {}},
        }, self.headers)
        if "error" in resp:
            raise RuntimeError(f"{tool}: {resp['error']['message']}")
        result = resp["result"]
        text = result["content"][0]["text"]
        if result.get("isError"):
            raise RuntimeError(f"{tool}: {text}")
        return text
