"""Shared MCP client for the MishMail helper scripts."""

import json
import os
import sys
import threading
import urllib.request
from pathlib import Path

DISCOVERY = (Path.home() / "Library/Containers/dev.ronboger.MishMail/Data"
             / "Library/Application Support/MishMail/mcp.json")


def post_json(url, payload, headers=None, timeout=180):
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", **(headers or {})})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


class MCP:
    """Minimal JSON-RPC client against the in-app MishMail MCP server."""

    def __init__(self, discovery=DISCOVERY):
        # Env wins over the discovery file: a launchd agent (or any process
        # without Full Disk Access) cannot read another app's sandbox
        # container, but the port is fixed and the token is stable, so both
        # can simply be supplied.
        token = os.environ.get("MISHMAIL_MCP_TOKEN")
        port = os.environ.get("MISHMAIL_MCP_PORT", "41888")
        if not token:
            if not Path(discovery).exists():
                sys.exit(f"MCP discovery file not readable ({discovery}) and "
                         "MISHMAIL_MCP_TOKEN is unset. Is MishMail running "
                         "with the MCP server enabled?")
            try:
                cfg = json.loads(Path(discovery).read_text())
            except PermissionError:
                sys.exit(f"No permission to read {discovery}. Set "
                         "MISHMAIL_MCP_TOKEN (and MISHMAIL_MCP_PORT) instead.")
            token, port = cfg["token"], cfg["port"]
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
