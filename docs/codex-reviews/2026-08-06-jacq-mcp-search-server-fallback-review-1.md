---
date: 2026-08-06 15:41
kind: review
target: branch jacq/mcp-search-server-fallback vs main
verdict: SHIP
model: claude-fable-5
requested_model: claude-fable-5
effort: low
job_id: review-20260806T154121-75556
reviewed_commit: 5baa96e746b6b6c2a5428353f67633f32a9ff1ef
started_at: 2026-08-06T22:41:21Z
finished_at: 2026-08-06T22:42:40Z
focus: MCP search_threads Gmail server fallback for uncached/old mail
---

# Review: MCP search_threads Gmail server fallback

## Prompt

Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: When the MCP can't find an email because it's too old (outside the local sync window), search_threads should use the same feature as the UI / search 'Search all of Gmail' button — pull matching messages from Gmail that aren't downloaded, then return them.

## Verbatim result

Couldn't run the test suite (approval denied), so this is a static review of the diff vs `main`.

# Review: MCP search_threads Gmail server fallback

## Findings

### Medium

**M1 — Tested helper `orderedUniqueGmailThreadIds` is dead code; the real logic is a duplicated inline copy.**
`SyncEngine.swift:365-381` defines `orderedUniqueGmailThreadIds(from:limit:)` "extracted for unit tests", but `fetchAll` (`SyncEngine.swift:322-329`) re-implements the same dedup/cap loop inline and never calls the helper. The rank-ordering test (`MCPServerSearchFallbackTests.swift:27-45`) therefore exercises a copy — the production loop can drift/regress without any test failing. Same pattern in `testThreadsByIdsPreservesCallerOrder` (`:57-89`), which re-implements `MCPBridge.threadsByIds`' ordering inline instead of calling it (it's `private`). The tests give a false sense of coverage on exactly the two behaviors the task cares about.

**M2 — Server-fallback results skip the `inTrash = 0` filter local search applies.**
`localSearchThreads` filters `WHERE inTrash = 0` on both FTS and LIKE paths (`MCPBridge.swift:169-197`), but `threadsByIds` (`MCPBridge.swift:198-207`) loads by id with no trash filter. A query whose only local hits are trashed returns `[]` locally → triggers the server pull → Gmail can list the same (trashed) threads → they now surface via MCP. Inconsistent with both the local path and, likely, user expectation. Suggested: filter `inTrash == false` in `threadsByIds` (unless the query explicitly says `in:trash`, which the server pass supports).

### Low

**L1 — Inline cap in `fetchAll` breaks collection at `limit` threads but keeps paging/downloading.**
The thread-id cap (`SyncEngine.swift:323 if matchedGmailThreadIds.count >= limit { break }`) stops recording, but the page loop continues on `listed < limit` (message count). Since a thread can have many messages, `matchedGmailThreadIds` can hit `limit` unique threads while `listed < limit` still fetches further pages — extra downloads whose thread ids are then discarded. Harmless correctness-wise (the change still re-derives them), just wasted network on the MCP hot path. Conversely, because `listed` counts messages, you may return fewer than `limit` threads even when Gmail has more — pre-existing behavior, just now user-visible via MCP.

**L2 — MCP fallback bypasses the `serverSearching` UI flag.**
`pullServerSearchMatches` (`MailStore.swift:2670`) is shared, but only `searchAllGmail` sets `serverSearching`/`syncStatus`. An MCP-triggered pull mutates the store (`applyThreadContentChange`) with no UI indication, and a concurrent UI "Search all of Gmail" can double-run the same query (SyncEngine actor serializes them, so it's just duplicate work, not corruption).

**L3 — Every zero-hit MCP search now hits the network.**
`shouldPullServerSearch` fires on *any* empty first page, including typo'd/garbage queries from an agent. Each is a Gmail list call (plus downloads when anything matches). Fine for correctness; worth knowing there's no throttle/negative-cache. Demo mode is correctly guarded (`MailStore.swift:2672`).

**L4 — `pullServerSearchMatches` per-account `limit` then global `prefix(limit)`.**
With multiple accounts, account A's hits fully occupy the cap and account B's downloads are wasted for the returned list (though still cached — arguably fine). Rank across accounts is concatenation, not global Gmail rank; document or interleave if it matters.

### Notes / non-issues verified

- Threading: `MailStore` is `@MainActor` (`MailStore.swift:230-232`), so the removal of the explicit `MainActor.run` wrappers in the refactored `searchAllGmail` path is correct — `applyThreadContentChange` and `lastError` writes stay main-actor isolated; `MCPBridge` hops correctly via `await store.pullServerSearchMatches`.
- `threadsByIds` preserves caller (Gmail rank) order and skips undelivered ids — matches the stated design; offset>0 correctly never re-triggers the server pass (server rank always starts at 0), and this is documented in the tool description.
- UI `searchAllGmail` behavior preserved: per-account error continuation, `serverSearching` reset, `syncStatus` clear.
- `refs.map(\.id)` cleanup and `FetchAllBatch` plumbing through `initialBackfill`/`fullBackfill`/starred backfill are mechanical and correct.
- Empty-server-result path deliberately keeps `[]` rather than erroring — reasonable for agents.

## Open questions

1. Is surfacing trashed threads via the server fallback intended (M2), or should `threadsByIds` filter them?
2. Should the fallback also fire when local hits exist but are few (e.g. `localCount < limit`)? Current policy (only when *zero*) means a single stale local hit suppresses older server mail — matches the UI button's manual nature, but agents can't press the button; flagging as a product decision.
3. `testSearchThreadsDescriptionMentionsServerFallback` asserts on prose — intentional? It's brittle to copy edits (low value as a test).

## Suggested fixes (not applied — read-only)

1. Replace the inline loop in `fetchAll` with a call to `orderedUniqueGmailThreadIds` (build refs list per page or make the helper incremental), so the tested code is the shipped code (M1).
2. Add `.filter(Column("inTrash") == false)` in `threadsByIds` (M2).
3. Optionally break the page loop when `matchedGmailThreadIds.count >= limit && missingIds.isEmpty` to avoid wasted paging (L1).
4. Consider setting `serverSearching` (or a lighter status) around the MCP-triggered pull (L2).

## Verdict

**SHIP** — with M1 (test/production drift) and M2 (trash leak) recommended as fast follows. No correctness regressions found in the refactored sync paths; the fallback policy is conservative and well-documented.
