---
date: 2026-08-10 10:35
kind: fable-iterate review
target: branch jacq/ship-20260810T101734-63046 vs main
verdict: ship-it
implementer_model: grok-4.5
grok_jobs: ship-20260810T101734-63046, rescue-20260810T102442-66667
reviewed_commit: af4bc72
reviewer: Claude Fable 5 (planner/reviewer per /fable-iterate)
---

# Review: deterministic Priority (starred) section under category filters

## Bug

User report: unchecking Updates in the Categories filter made *more* starred
messages appear, several of which were not Updates.

Root cause: `reloadThreads` fetches one 100-row date-desc page
(`ThreadListPaging.pageSize`); `PrioritySplit.partition` in `ThreadListView`
only sees that page. Hiding a category removes its unstarred rows from the
SQL page, so the page reaches further back in time and older starred threads
(any category, within the 7-day Priority window) newly enter the page and get
hoisted into the pinned "Starred" section. Working as coded, but Priority
membership depended on page depth — nondeterministic under filter toggles.

## Fix (commits 850910f, 029bebd, af4bc72)

- New `Sources/MishMail/Support/PriorityCandidates.swift` (hostless, pattern
  of `CategoryHide`): a capped candidate query (`.starred` /
  `.starredImportant`) over the same filtered list request, ordered by the
  list sort key, plus a sorted-merge helper (dedupe by id, order preserved).
  IMPORTANT match is token-exact (`' '||labelIds||' ' LIKE '% IMPORTANT %'`);
  IMPORTANT-only candidates respect hidden categories, mirroring
  `PrioritySplit.qualifies`.
- `MailStore.reloadThreads` (inbox, starred modes only): fetch candidates in
  the same `pool.read`, merge into the page before VIP scoring. `hasMore`
  unchanged.
- Review finding (fixed in 029bebd via rescue): the load-older cursor was
  computed from the *merged* list, so an older merged-in candidate became the
  paging watermark and "Load older" would skip every row between the true
  page bottom and that candidate. Now the cursor comes from the unmerged page
  (reload) / the freshly fetched page (load-more), carried via
  `ReloadPayload.nextCursor`.
- af4bc72 (reviewer): Grok's new cursor test referenced a nonexistent `d()`
  helper and didn't compile; defined the local helper. (Grok could not run
  `make test` in its sandbox — SPM resolve blocked — so this was caught in
  the supervisor test run.)

## Review checks

- `labelIds` confirmed space-separated (`Database.swift:28`), so the token
  LIKE is correct and avoids substring false-positives.
- Hidden-category set: inbox uses chips (`effectiveCategoryHide` falls back
  to chips outside saved views); Priority split is inbox-only, so snapshotting
  `chips.category.hide` is correct.
- Candidates capped at `priorityMaxCount` (default 10; ≤0 → hard bound 200),
  windowed by `lastDate >= cutoff` — matches `PrioritySplit` semantics, so
  merged extras are hoisted, not left dangling mid-list (extras are always
  older than the page bottom; partition takes newest-first).
- Search branch, starKeepIds pin-through, CategoryHide semantics, loadOlder
  dedupe: untouched / verified unchanged.
- No string-interpolated user input in SQL (category ids are constants, same
  as existing `CategoryHide`).

## Tests

`make test`: 1368 tests, 0 failures (run by reviewer outside the sandbox).
New `PriorityCandidatesTests` covers: hide-toggle invariance (core
regression), window cutoff, cap, starredImportant hidden-category rules,
merge dedupe/ordering, and the paging-cursor watermark.

Verdict: **SHIP**.
