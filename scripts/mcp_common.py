"""Shared MCP client for the MishMail helper scripts."""

import json
import sys
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
        if not Path(discovery).exists():
            sys.exit(f"MCP discovery file not found ({discovery}). "
                     "Is MishMail running with the MCP server enabled?")
        cfg = json.loads(Path(discovery).read_text())
        self.url = f"http://127.0.0.1:{cfg['port']}/mcp"
        self.headers = {"Authorization": f"Bearer {cfg['token']}"}
        self._id = 0

    def call(self, tool, args=None):
        self._id += 1
        resp = post_json(self.url, {
            "jsonrpc": "2.0", "id": self._id, "method": "tools/call",
            "params": {"name": tool, "arguments": args or {}},
        }, self.headers)
        if "error" in resp:
            raise RuntimeError(f"{tool}: {resp['error']['message']}")
        result = resp["result"]
        text = result["content"][0]["text"]
        if result.get("isError"):
            raise RuntimeError(f"{tool}: {text}")
        return text
