---
date: 2026-07-28 14:45
kind: review
reviewer: Fable (jacq-claude, claude-fable-5)
target: branch fix/unstar-stickiness vs main (commit 3082a28)
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260728T144322-37892
reviewed_commit: 3082a28b9a66c37b6a6af7be671baa94bf5c1606
invoked_from: /Users/ronboger/mishmail/.worktrees/unstar-stickiness
git_branch: fix/unstar-stickiness
focus: >
  Re-review after pass-1 LOWs: label:starred stickiness + tighten
  excludePromotions gate.
---

# Prompt

```
[jacq-claude] Mode: READ-ONLY. Do not modify project files. Analyze and report only.

You are a careful code reviewer. Focus on correctness, security, edge cases, and test gaps. Be specific (file:line).
Compare against git ref 'main' (diff / log as needed).
Focus: Re-review the complete diff against main after addressing pass-1 LOWs (label:starred / STARRED system-label stickiness + tighten excludePromotions gate). Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Original task: when unstarring something not in current categories, don't remove the thread from view so user can continue working. Apply same stickiness wherever starring gates list membership.

Deliver:
1. Findings ordered by severity with evidence
2. Open questions
3. Suggested fixes (do not apply unless write mode was requested)

Do not modify files unless explicitly told to write.
```

# Review

id:	review-20260728T144322-37892
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/unstar-stickiness
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260728T144322-37892/output.log
---
# Re-review: unstar stickiness (vs `main`)

Reviewed the full diff: `MailStore.swift` (+~120), `CategoryHide.swift`, two test files, plus the review-1 doc. I could not run `swift test` (approval denied in this sandbox), so test results are unverified by me; the tests read as internally consistent.

## Findings

**LOW-1 — Pins can arm from an inactive filter layer (search vs chips).**
`starStateFilterActive` (MailStore.swift:1303) checks `chips.category.hide`, `chips.labelId == "STARRED"`, and the selected view unconditionally, but when a `/` search is committed, `reloadThreads` takes the search path and those chips/view filters are not applied. Unstarring during a plain `invoice` search while a hide chip is set pins the id; when the search clears (`clearSearch` → reload with hide still active), the thread appears in the hide-gated list even though it was never visible there mid-triage. Cosmetic and self-healing on view/filter change; readState has the analogous asymmetry. No action strictly needed.

**LOW-2 — Pins survive across different star-gated filters.**
`reloadThreads` clears `starStateKeepIds` only when `starStateFilterActive` is false (:1978). Committing a new `is:starred from:bob` search after unstarring under the Starred mailbox keeps the old pin (the row can show under an unrelated star-gated search). Exact parity with `readStateKeepIds` behavior, so this is a deliberate trade-off, not a regression.

**INFO — Test fidelity.**
`StarUnstarStickinessTests` mostly *mirrors* production SQL rather than calling it (documented in the header; MailStore is AppKit-bound). Exceptions: `CategoryHide.apply/applyExcludePromotions` tests exercise the real code — good. `filterThreads` is `nonisolated static` and looks callable from the hostless target; `testLabelStarredFilterKeepIds` hand-copies its SQL instead. If `MailStore.filterThreads` is importable there, calling it directly would remove one drift risk. Not blocking.

## Correctness verification (things I checked and found right)

- **Pass-1 LOWs addressed correctly.** `label:starred`/`label:STARRED` search now arms the gate via case-insensitive label match (:1327-1330), and `filterThreads` STARRED case widens with parameterized `id IN (...)` (:2592-2598) — placeholders + args, no injection. `excludePromotions` legacy gate is now correctly conditional on chipsJSON being absent (:1313-1321), exactly mirroring `baseQuery`'s `break` before `v.excludePromotions` (:2528-2556).
- **Pin-before-mutate ordering** in `toggleStar` (:4352-4353) and `setStarForChecked` (:4366) — optimistic leave-list and reload both see the id.
- **Clearing sites complete:** view change (:267), account change (:1219), filter-inactive reload (:1978), and `dropKeepId` on optimistic remove (:4037-4040). Trash/archive still wins over stickiness (leave-list ordering at :4085-4088 is correct: kept-unstarred falls through to the location check, so trashing a pinned row still removes it).
- **All star-gated query paths widened consistently:** `.starred` baseQuery, `.label` STARRED view, saved-view `starredOnly` (both chipsJSON and legacy), `label:` chip, `is:starred` search, `label:starred` search, CategoryHide (all three branches incl. Updates/Forums LIKE), legacy excludePromotions, and both `reloadThreads` and the load-more probe (:2276-2284).
- **No keep-leakage to counts:** `SidebarCounts` doesn't consume CategoryHide/keepIds, so counts reflect true state while the row is pinned — same as readState.
- **Tests cover** the trash/archive non-resurrection edges, the gate matrix (incl. the negative cases `is:unread`, `label:work`), and the unstar round-trip through real `CategoryHide`.

## Open questions

1. Is star-count-vs-visible-row divergence (Starred count says 3, list shows 4 with a pinned row) acceptable? It matches readState precedent, so I assume yes.
2. `swift test` unrun here — please confirm the suite passes locally/CI.

## Suggested fixes (optional, do not apply)

- LOW-1: gate the chips/view checks in `starStateFilterActive` behind `committedSearch.isEmpty` (search path replaces them), keeping only the search-operator checks when a search is active.
- INFO: swap the hand-copied SQL in `testLabelStarredFilterKeepIds` for a direct `MailStore.filterThreads(...)` call if the hostless target links it.

## Verdict

**SHIP** — both pass-1 LOWs are fixed correctly, the gate matches the query paths exactly, and remaining findings are parity-consistent cosmetic edges. Contingent on the test suite passing (unverified here due to sandbox).
