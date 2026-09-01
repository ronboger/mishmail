
## MCP helper scripts

These drive the in-app MCP server (Settings → AI → MCP must be on, MishMail
running). They read the port from `mcp.json` in the app container. The bearer
token stays in the Keychain; set `MISHMAIL_MCP_TOKEN` or put it in
`~/.config/mishmail/mcp-token`. Older `mcp.json` files that still include
`token` continue to work.

- `mcp-summarize.py` — backfill thread summaries. Local Ollama by default
  (`--backend ollama --model llama3.2:3b`, nothing leaves the machine) or any
  OpenAI-compatible API (`--backend openai --api-base ... --model ...`, needs
  `OPENAI_API_KEY`). Skips threads that already have a summary unless `--redo`.
- `mcp-export-threads.py` / `mcp-import-summaries.py` — the two-file bridge for
  summarizers that can't reach 127.0.0.1 (Codex Cloud workers, remote batch
  jobs). Export to JSONL, have the remote job emit
  `{"thread_id", "summary"}` lines, import them back.
- `mcp_common.py` — shared MCP JSON-RPC client used by the above.

The exported JSONL contains full message bodies; treat it like the mailbox.
