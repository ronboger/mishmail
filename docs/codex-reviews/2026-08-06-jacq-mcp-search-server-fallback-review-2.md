---
date: 2026-08-06 15:45
kind: review
target: branch jacq/mcp-search-server-fallback vs main (pass 2 after M1/M2 fixes)
verdict: SHIP
model: claude-fable-5
requested_model: claude-fable-5
effort: low
job_id: review-20260806T154420-78176
reviewed_commit: 8ccbb7318aad601c62f6d303ce2eed52fff08f2e
started_at: 2026-08-06T22:44:20Z
focus: re-review M1/M2 fixes for MCP search server fallback
---

# Re-review: MCP search server fallback (pass 2)

## Prompt

Re-review after addressing pass-1 findings M1 and M2.

Pass 1 was SHIP with recommended follows. Changes since 5baa96e:
1. M1: fetchAll now calls SyncEngine.appendUniqueGmailThreadIds (same helper as orderedUniqueGmailThreadIds used by tests); added cross-page unit test.
2. M2: MCPBridge.threadsByIds filters inTrash == false to match localSearchThreads; test asserts trashed threads are dropped.

Still intentionally not addressing L1-L4 (paging waste, UI serverSearching flag, empty-query network hits, multi-account rank) — low severity product notes.

Verify fixes, check for new issues, finish with SHIP or NOT READY.

## Verbatim result

MailStore is `@MainActor` (MailStore.swift:230), so `pullServerSearchMatches` doing `applyThreadContentChange` without a hop is correct, and MCPBridge's `await store.pullServerSearchMatches(...)` (MCPBridge.swift:138) hops properly. All `searchServer` callers use the new tuple result. I attempted to run the new test suite but the command required approval and was denied, so tests were not executed in this session.

## Re-review: MCP search server fallback (pass 2)

### M1 verification — production/test path unification ✅
`fetchAll` now calls `Self.appendUniqueGmailThreadIds` directly (SyncEngine.swift:326), and `orderedUniqueGmailThreadIds` (SyncEngine.swift:384-391) is a thin wrapper over the same helper. `testAppendUniqueGmailThreadIdsAcrossPages` exercises cross-page dedup + cap with a shared `seen` set, including the "cap at 3, skip already-seen" case. Coverage can no longer drift. Fixed as claimed.

### M2 verification — trash filtering ✅
`threadsByIds` (MCPBridge.swift:200-211) adds `.filter(Column("inTrash") == false)`, matching `localSearchThreads`' `WHERE inTrash = 0`. Test seeds a trashed thread in `order` and asserts it's dropped while caller order is preserved. Fixed as claimed.

### Findings

**Low — test mirrors implementation instead of calling it.** `testThreadsByIdsPreservesCallerOrder` re-implements the query inline ("Mirrors MCPBridge.threadsByIds") because the method is private and bound to `AppDatabase.shared`. If `threadsByIds` changes (e.g. drops the trash filter), the test keeps passing. The comment acknowledges this; acceptable, but extracting a `static func threadsByIds(_ db: Database, ids:, limit:)` would make it real coverage. Not blocking.

**Low — all-trashed server hits silently degrade to `[]`.** If Gmail lists only trashed matches, `serverIds` is non-empty, `threadsByIds` returns `[]`, and the agent sees `[]` with no hint. Consistent with the "agents see [] rather than a confusing error" design comment (MCPBridge.swift:141-142); fine as designed.

**Info — helper edge cases are correct.** `appendUniqueGmailThreadIds` returns before inserting into `seen` when at cap, so a later page can't sneak past the limit; `limit <= 0` guard covered by test. `pullServerSearchMatches` caps the cross-account union at `limit` via `prefix(max(limit, 0))`.

**Not verified:** could not execute `swift test --filter MCPServerSearchFallbackTests` (command approval denied). Test logic reads correct by inspection; recommend running before merge.

### Open questions
- None blocking. L1–L4 remain intentionally deferred per the brief.

### Verdict: **SHIP**

Both pass-1 findings are fixed exactly as described, with tests. No new issues above Low severity; the one caveat is that the test suite wasn't executed in this read-only session.
