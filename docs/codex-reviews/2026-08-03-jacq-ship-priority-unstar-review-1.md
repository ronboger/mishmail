---
date: 2026-08-03 01:00
kind: fable-iterate review (Claude reviewer, Grok implementer)
implementer_model: grok-4.5
grok_jobs:
  - ship-20260803T005424-81257
  - rescue-20260803T005821-84723
branch: jacq/ship-20260803T005424-81257
reviewed_commit: c3a91f2 (on top of d876cbd)
base: main (8325d5b)
verdict: SHIP
tests: make test — 1242 executed, 0 failures (5 skipped)
---

# Review: Priority-section unstar auto-advance

## Bug

In the unified all-accounts inbox, unstarring the focused thread in the pinned
Priority section never triggered auto-advance: the thread stays in the list
(it is still in the inbox), so `MailStore.toggleStar` → `mutateThread` runs
with no `autoAdvanceAction` and none of the leave-list removal machinery
fires. On the next `recomputeLayout` the row re-partitions out of the
Priority section into the date groups below; list selection follows the moved
row, landing the user amid unstarred mail instead of on the next starred
email.

## Fix (as implemented)

- New pure helper `Sources/MishMail/Support/PrioritySectionAdvance.swift`:
  - `idsLeavingSection` — targets that are currently in the Priority section
    and would no longer qualify with `isStarred = false` (VIP-pinned and,
    under `.starredImportant`, IMPORTANT-labeled rows correctly stay; `.off`
    guarded to return nothing — added by the rescue commit after my review
    caught the missing guard via the failing test).
  - `destinations` — `SelectionAdvance.destinations` restricted to the
    Priority section's own display order (down, then up; Gmail style).
- `MailStore`: new `prioritySectionIds` kept in sync by
  `ThreadListView.recomputeLayout` through the extended
  `updateDisplayOrder(_:prioritySectionIds:)`; new
  `advanceForPriorityUnstar` called from the unstar branches of `toggleStar`
  and `toggleStarChecked` (after `pinStarStateKeep`, before the mutation).
  Reads `priorityMode` / `vipAlwaysPins` from UserDefaults with the same
  defaults as the view's `@AppStorage` (absent `vipAlwaysPins` → true).
  Mirrors `advanceForRemoval` ordering: `openDetail` first, then
  `setSelectionFocus(.autoAdvance)`. When the section empties, deliberately
  no-op (selection stays on the still-listed row).
- Correct interaction with star stickiness: the `.autoAdvance` selection write
  drops the just-added thread-long unstar pin for the now-unselected row, so
  hidden-category mail leaves Primary as designed (documented in comments).
- Tests: `PrioritySectionAdvanceTests` — mid-section advance, last-row
  upward fallback, only-row → nil, VIP pin, IMPORTANT under
  starredImportant, mode off, out-of-section target, selected/opened
  independence. Wired into `project.yml`.

## Review notes

- Only caller of `updateDisplayOrder` is `ThreadListView.recomputeLayout`, so
  the defaulted `prioritySectionIds: []` parameter cannot silently go stale
  from another call site.
- Non-inbox views pass an empty priority array (partition mode `.off` off
  inbox), and `advanceForPriorityUnstar` additionally guards
  `selectedView == .inbox` — consistent double gate.
- Pass 1 found one defect: `idsLeavingSection` missing the `.off` guard
  (caught by the suite: `testModeOffYieldsEmptyLeaving` failed). Fixed by
  rescue job in commit c3a91f2. Pass 2: full suite green.
- No unrequested changes; diff is scoped to the five expected files.

## Verdict

SHIP — merged into `main`.
