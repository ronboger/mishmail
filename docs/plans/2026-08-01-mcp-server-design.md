# MishMail MCP Server — Design

Date: 2026-08-01. Author: Claude (Fable 5), implementer: Grok 4.5 via jacq-grok.

## Goal

Let external AI models/agents (Claude, Grok, cheap hosted models like "5.6 Luna low")
connect to MishMail and take actions: read/search threads, manage drafts, **write
persisted AI thread summaries**, and **insert VIP senders** (e.g. a model parses the
mailbox and suggests VIPs).

## Shape: in-process MCP server, Streamable HTTP on 127.0.0.1

Rationale (from architecture survey):

- All data is one SQLCipher GRDB file keyed from the app-bundle-scoped Keychain; an
  out-of-process server could read it only fragilely and could never write safely —
  writes that must reach Gmail go through `MailStore` (optimistic mutation +
  `GmailClient` call + resync) and there is no durable action queue to replay.
- The app sandbox already has `com.apple.security.network.server` (OAuth loopback),
  and `Auth/OAuth.swift` is prior art for a loopback `NWListener` HTTP handler.
- MCP's Streamable HTTP transport allows plain JSON request/response (no SSE
  required); modern clients (Claude Code/Desktop, etc.) speak it natively via
  `{"type":"http","url":...,"headers":{Authorization}}`.

So: a minimal, dependency-free JSON-RPC 2.0 over HTTP/1.1 server inside the app.

## Transport & security

- Bind 127.0.0.1 only, ephemeral port. Endpoint `POST /mcp` (JSON in/JSON out).
  `GET /mcp` → 405. Anything else → 404.
- **Off by default.** Settings toggle "MCP server" starts/stops it.
- Bearer token: 32 random bytes hex, generated on first enable, stored in Keychain
  (`mcp.token`). Every request must carry `Authorization: Bearer <token>` → else 401.
- Discovery file for clients: `<Application Support>/MishMail/mcp.json`
  (inside the container), `{"port": N, "token": "...", "pid": ...}`, permissions 0600,
  rewritten on every start, deleted on stop/quit. Settings UI shows the full
  container path and a copyable Claude Code `claude mcp add` snippet.
- JSON-RPC methods: `initialize` (protocolVersion "2025-06-18", capabilities
  `{tools:{}}`, serverInfo mishmail/version), `notifications/initialized` (accept,
  202 empty), `ping`, `tools/list`, `tools/call`. Unknown method → -32601.

## Persistence addition: migration v31 `threadSummary`

```sql
threadSummary(threadId TEXT PRIMARY KEY REFERENCES thread ON DELETE CASCADE,
              summary TEXT NOT NULL, model TEXT NOT NULL, updatedAt DATETIME NOT NULL)
```

Mirrors `threadAI`. `ThreadDetailView` shows the persisted summary in the existing
AI-summary section when no ephemeral one exists, with a "Summarized by <model>"
caption; local Ollama Summarize still works and takes precedence when run.

## Tools (v1)

| tool | args | behavior |
|---|---|---|
| `list_accounts` | — | account ids/emails |
| `list_threads` | `mailbox` (inbox/starred/sent/drafts/all), `unread_only?`, `limit<=100`, `account?` | DB read; returns id, subject, snippet, from, date, flags, persisted summary if any |
| `search_threads` | `query`, `limit<=100` | FTS5 (subject/from) with LIKE fallback |
| `get_thread` | `thread_id` | full thread as Markdown via `ThreadExporter`, hydrating `message_body` |
| `list_drafts` | `account?` | draft messages (DRAFT label) |
| `create_draft` | `account`, `to[]`, `cc?[]`, `bcc?[]`, `subject`, `body`, `reply_to_thread_id?` | `MailStore.saveDraft` on MainActor → real Gmail draft |
| `set_thread_summary` | `thread_id`, `summary`, `model` | upsert `threadSummary` |
| `list_vips` | — | vip emails + groups + enabled state |
| `add_vip` | `email`, `group?` (default `"Suggested"`) | `MailStore.addVIP`; creates group row if new |
| `remove_vip` | `email` | `MailStore.removeVIP` |

Deliberately excluded from v1: send, archive/trash/label mutation, delete draft —
keep the blast radius small; drafts are reviewable by the user before sending.

## Concurrency

- Server: `NWListener` on a background queue; per-connection minimal HTTP/1.1 parse
  (request line + headers + Content-Length body, `Connection: close`).
- Reads go straight to `AppDatabase.shared` (GRDB pool reads are thread-safe).
- Mutations (`create_draft`, VIP ops) hop to `@MainActor` `MailStore`.
- Server owned by `MailStore` (start/stop with app lifecycle; stopped in shutdown
  path before DB close).

## Testing

Pure-logic XCTests (matching repo convention): HTTP request parsing, auth check,
JSON-RPC dispatch/error codes, tool schema list, summary upsert + migration v31,
VIP add default-group behavior, draft-arg validation. No network in unit tests.
