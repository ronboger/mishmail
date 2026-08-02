---
date: 2026-08-01 13:20
kind: fable-iterate review
target: branch jacq/mcp-server vs claude/mishmail-mcp-design-e36d06
verdict: SHIP
implementer_model: grok-4.5
grok_job_id: ship-20260801T125115-69547
reviewed_commit: 9bfc591d6a24bea6d4793d80cdff88aed60b64e2 (+ fb71f50 test fix by Claude)
git_branch: jacq/mcp-server
---

# Review — MishMail in-process MCP server (pass 1)

Scope: 14 files, +1904/−1. Design: docs/plans/2026-08-01-mcp-server-design.md.

## Verification

- `make gen && make build`: exit 0, no errors (Grok was sandbox-blocked on SPM; re-ran outside).
- `make test`: **1213 tests, 0 failures** after one fix (below).

## Defect found & fixed

- `MCPHTTPTests.testParseCompleteRequest`: fixture declared `Content-Length: 18` for a
  17-byte body, so the (correct) parser returned nil. Test bug, not code bug. Fixed by
  Claude directly (fb71f50) — a one-character change wasn't worth a rescue round-trip.

## Review findings

Correct and faithful to the design:
- MCPHTTP: pure parser (CRLF framing, lowercased headers, Content-Length gating,
  query-strip), response always `Connection: close`; bearer extraction case-insensitive.
- MCPRouter: JSON-RPC 2.0 with correct codes (-32700/-32601/-32602), MCP `isError`
  results for tool failures, `notifications/initialized` → 202 empty, protocolVersion
  2025-06-18, 10 tools with JSON Schema.
- MCPServer: 127.0.0.1-only NWListener (mirrors OAuth prior art), 2 MB cap,
  404/405/401 gating before dispatch, token required non-empty.
- MCPBridge: GRDB pool reads off-main; mutations hop to MainActor MailStore
  (saveDraft silent+syncAfter, addVIP default group "Suggested", removeVIP).
  labelIds DRAFT match uses the space-separated padding trick — verified format
  matches `Message.labelIds` ("space-separated Gmail label ids"). Reply parent =
  newest non-DRAFT message. Account/thread existence validated before mutation.
- v31 `threadSummary` with ON DELETE CASCADE; record mirrors ThreadAICategory style.
- Lifecycle: MCP stopped in `executeTermination()` **before** DB shutdown; mcp.json
  (0600) written on start, removed on stop/quit. Token via existing
  `Keychain.existingOrCreate` (32 random bytes hex).
- Settings UI (AI pane, off-by-default toggle, port/discovery path/copyable
  `claude mcp add` snippet) and reading-pane persisted-summary display with
  "Summarized by <model>", ephemeral Ollama taking precedence — both per design.
- project.yml: pure helpers added to hostless test target; xcodeproj regenerated.

Accepted minor notes (not blockers, documented for later):
1. Token comparison is not constant-time — acceptable: loopback-only, 256-bit random
   token, timing oracle impractical over TCP loopback for equal-length hex compare.
2. Quit race: an in-flight tool Task could straddle `stopMCPServer()` and DB close.
   Window is milliseconds and GRDB's beginShutdown/interrupt path mitigates; same
   exposure class as other startup-tail work.
3. `ISO8601DateFormatter()` allocated per row in list payloads — perf nit at limit≤100.
4. Listener `.failed` state is swallowed (no auto-restart); Settings still shows
   running. Rare (loopback), user can toggle off/on.

## Verdict

SHIP — merge `jacq/mcp-server` into `claude/mishmail-mcp-design-e36d06` (worktree
branch only; NOT main, per Ron's instruction).
