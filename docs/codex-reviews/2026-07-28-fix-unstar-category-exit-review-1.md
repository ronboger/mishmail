---
date: 2026-07-28 23:04
kind: review
reviewer: Fable (jacq-claude, claude-fable-5)
target: branch fix/unstar-category-exit vs main (commit 2acce1a)
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260728T225920-31155
reviewed_commit: 2acce1a88a89e1e86dfd6505ddb05ec369cc2bb7
invoked_from: /Users/ronboger/mishmail/.worktrees/unstar-category-exit
git_branch: fix/unstar-category-exit
focus: >
  Category-hide unstar stickiness exits on leave-thread; session stickiness
  for Starred/is:starred; plan APPROVE WITH CHANGES items addressed.
---

# Review: `fix/unstar-category-exit` vs `main` (commit 2acce1a)

## Findings (by severity)

**No HIGH or MEDIUM issues.** The core policy split, drop paths, and optimistic leave are correct:

- **Policy split** — `StarStickiness.policy` (StarStickiness.swift:24-58) correctly returns `.session` for Starred mailbox / `label:STARRED` (view, chips, saved) / `is:starred` & `label:starred` search, `.thread` only for category hide, `.session` winning when both apply (session checks precede hide checks). Committed search masks chips/view filters and returns `.none` unless search operators arm the gate — matches `reloadThreads` semantics, covered by `testCommittedSearchMasksHideChips`.
- **Selection drop site** — `selectedThreadId` setter (MailStore.swift:281-293) is genuinely the single funnel: `selectThread` → `setSelectionFocus` writes it, `moveSelection` and `advanceForRemoval` route through `setSelectionFocus`, and direct List-binding writes hit it with `pendingSelectionIntent == nil → .click` (drop is correct for click). The `old != newValue` guard prevents no-op drops; `setSelectionFocus` nils the intent on same-id writes so it can't go stale there.
- **restoreFocus exemption** — `selectionDropsThreadPins` (StarStickiness.swift:62-67) exempts only `.restoreFocus`; `restoreSelectionFocus` (MailStore.swift:4079-4082, undo path) uses it. Correct: undo re-select doesn't yank pins.
- **Uncheck/clear paths** — `clearCheckedThreads` and `toggleCheckedThread` pass `selectionIntent: nil` → unconditional drop of unretained pins under `.thread` (MailStore.swift:1237-1266). Unchecking the currently-selected thread correctly retains its pin via `id != selectedId`.
- **Optimistic leave** — drop pass removes rows via `leavesDueToCategoryHide` after removing ids from `keepIds` (order is right: `isKept` re-check sees the post-drop set, MailStore.swift:1394-1405), and `threadLeavesCurrentList` for inbox/account now also leaves on category hide when unkept (MailStore.swift:4184-4192). Star always pins through. Session pins under Starred (`case .starred`, :4198-4200) unchanged.
- **Session lifetime** — `selectedView.didSet` (:267) and `reloadThreads`'s `if !starStateFilterActive { starStateKeepIds.removeAll() }` (:2057) still clear on view/filter change.
- **Archive/trash immediate removal** unchanged (`ThreadListOptimistic.plan` remove wins over keepIds, :4088-4120); no auto-archive added anywhere.
- **`effectiveCategoryHide`** correctly reads saved-view `chipsJSON` / legacy `excludePromotions` for the drop-removal pass, since `baseQuery` for saved views doesn't read live chips.

**LOW-1 — per-selection-change policy recompute with JSON decode.** `applyThreadLongStarPinDrops` runs on every selection change (each j/k step) and `currentStarStickinessPolicy()` decodes saved-view `chipsJSON` each time (MailStore.swift:1354-1361, 1384). Given this codebase's explicit care about key-repeat cost (that's why `listFocus` exists), consider early-returning when `starStateKeepIds.isEmpty` before computing policy. Not a correctness issue — pins are rare.

**LOW-2 — pin on unselected unstar lingers until next drop trigger.** Unstarring a thread that's neither selected nor checked (hover star toggle) still arms a pin (`pinStarStateKeep`, :4074-4077) retained by nothing; it survives until the next selection change/uncheck fires a drop pass. Benign and arguably fine ("row doesn't vanish under the pointer"), but note the row's exit is then triggered by an unrelated click elsewhere, which can look like spooky action.

**NIT — dead code**: `checkedThreadIds.remove(t.id)` inside the drop-removal loop (:1406) is a no-op — `idsToDrop` already excludes checked ids.

**NIT — non-consuming intent read**: the setter reads `pendingSelectionIntent` without consuming; a stale intent would require a direct binding write landing between a programmatic `setSelectionFocus` and its `onChange` consume. Practically unreachable given the synchronous write sequence.

## Test coverage

Good. `StarStickinessPolicyTests` (20 tests) covers all policy arms, session-wins-over-thread, search masking, drop-set computation under both policies, restoreFocus exemption, nil-intent uncheck pass, checked retention, category-hide leave incl. denorm promo and star/keep pin-through, plus an end-to-end thread-long exit model. `StarUnstarStickinessTests` gate helper now delegates to the production `StarStickiness.policy` (previously a hand-mirrored copy — nice), with a new regression for hide-chips-masked-by-search. `project.yml` adds the file to the hostless test target. Gap: no test exercising the `effectiveCategoryHide` saved-view chipsJSON path in the drop-removal (only live chips are covered) — worth one test if the file is touched again.

## Open questions

1. LOW-2: should an unselected/unchecked unstar skip pinning (drop immediately) under `.thread` policy, or is the current "stays until next interaction" intentional?
2. `.quiet` (auto-select top row) drops pins — since it only fires when selection is already nil (a drop already happened at that transition), this is moot today, but if `.quiet` gains other call sites the classification should be revisited.

## Verdict: **SHIP**

## Follow-up (post-review)

Addressed LOW-1 (early return when keepIds empty), LOW-2 (pinStarStateKeep under thread policy immediately drops unretained pins), and NIT dead checkedThreadIds.remove.
