# Review: sent-without-reply threads unfindable by recipient search

- date: 2026-08-03
- grok job: ship-20260803T101553-82001 (model grok-4.5, verified via `jacq-grok status --json`)
- branch: jacq/ship-20260803T101553-82001
- reviewed commit: b940b7a21125c2daff72334e9ce6ae565c282007
- verdict: **SHIP**
- reviewer: Claude (Fable 5), pass 1

## Bug

Local search (`/` typeahead, committed search, MCP `search_threads`) never
surfaced sent emails with no reply when searching by recipient name or
address (e.g. the "surgery update" email to claire@ferrariortho.com).

Root cause: migration v17 trimmed `message_fts` to index only `subject` +
`fromHeader`. On a thread with replies the counterparty appears as a sender;
on a sent-only thread they exist only in `toHeader`/`ccHeader`, which were
not indexed. Confirmed empirically against the live DB via MCP: FTS query
"claire"/"ferrariortho" missed the sent-only thread; subject query hit it.

## Change reviewed

- New migration `v33` in `Sources/MishMail/Store/Database.swift`: drops
  `message_fts_vocab` first (per v31 WARNING), drops FTS sync triggers and
  `message_fts`, recreates FTS with `subject`, `fromHeader`, `toHeader`,
  `ccHeader`, `synchronize(withTable: "message")` (auto-repopulates),
  `prefixes = [2, 3]`, then recreates the vocab table. Correct ordering.
- One-line cross-reference comment added at the v17 trim comment; migration
  bodies untouched.
- Tests: `ThreadTypeaheadTests.testFindsSentOnlyByRecipientNameAndAddress`
  (recipient name, address domain, and subject queries on a sent-only
  thread) and
  `DatabaseMigrationTests.testUpgradeToV33IndexesRecipientHeadersAndKeepsVocab`
  (pre-v33 negative check, post-v33 four-column schema, bodyText still
  omitted, prefixes kept, vocab recreated and reflecting new terms). Fresh-
  migrate assertions extended for the four columns + vocab.

## Verification

- Grok's sandbox blocked SPM resolution, so the suite was run by the
  reviewer in the worktree: `make test` → **1244 tests, 0 failures**
  (5 skipped), TEST SUCCEEDED.
- Diff is minimal (3 files, +176 lines, all migration + tests). No changes
  to server search, MCP LIKE fallback, or SearchQuery parsing. No
  unrequested changes.

## Notes

- Body text remains unindexed (deliberate v17 tradeoff); body search still
  falls back to server search.
- `bccHeader` intentionally not indexed (matches Gmail search behavior of
  not exposing bcc broadly; low value, and keeps index smaller).
