---
date: 2026-07-28 22:55
kind: plan-review
reviewer: Fable (jacq-claude, claude-fable-5)
target: plan docs/plans/2026-07-28-unstar-category-exit.md (pre-implementation)
verdict: APPROVE WITH CHANGES
model: claude-fable-5
effort: low
job_id: rescue (read-only plan review)
invoked_from: /Users/ronboger/mishmail/.worktrees/unstar-category-exit
git_branch: fix/unstar-category-exit
---

# Plan Review: unstar-category-exit

Read the plan, `CategoryHide.swift`, the relevant `MailStore.swift` paths, `StarUnstarStickinessTests.swift`, and the prior Fable SHIP doc. The product model split (thread-long for category hide, session-long for star-gated lists) is right and matches the screenshot complaint. The implementation sketch has real wiring gaps.

## 1. Findings by severity

**HIGH-1 — Hooking `setSelectionFocus` misses direct List-binding selection changes.**
`selectedThreadId` is a computed property over `listFocus.id` (MailStore.swift:276–279), and `consumeSelectionIntent` (:3757) exists precisely because "Direct List bindings / legacy call sites" set selection *without* going through `selectThread` → `setSelectionFocus`. A plain click via a SwiftUI `List(selection:)` binding writes the setter directly; the plan's step 2 hook never fires and the pin sticks forever — the exact bug being fixed, on the most common interaction path. The drop must live in the `selectedThreadId` setter (or a `listFocus.id` didSet), or every binding site must be audited/funneled. The plan's parenthetical "or immediately after selection id changes in selectThread" has the same hole.

**MEDIUM-1 — Step 3 (optimistic hide leave) is required, not optional, for step 2 to do anything visible.**
Step 2.2 says "reuse `applyOptimisticThreadUpdate` … or a narrow reload." But `threadLeavesCurrentList` for `.inbox`/`.account` (:4094–4102) never consults category hide, so `plan.effect` will be `.updateInPlace` and the row stays until async reload — the plan's own success criterion ("row leaves list without requiring sidebar/view change") then depends on a reload the sketch only mentions as an alternative. Either commit to step 3 or make "drop pin + `reloadThreads()`" the explicit mechanism. Don't leave both halves optional.

**MEDIUM-2 — No drop hook for uncheck.**
The plan answers its own Q2 with "keep while checked OR selected," but the implementation sketch only wires selection changes. Unchecking B via `toggleChecked` (:1230) doesn't move selection, so B's pin survives until view change — a policy violation the plan itself defines. Need a drop pass on `checkedThreadIds` shrink (toggleChecked remove-path, `clearCheckedThreads` :1223). Note the post-reload intersection at :2161–2163 does *not* help here — it only unchecks rows that already left.

**MEDIUM-3 — Undo/restore-focus will spuriously drop pins.**
`restoreSelectionFocus` (:4000) and auto-advance both route through `selectThread` with intents `.restoreFocus`/`.autoAdvance`. Undoing a trash on thread X while an unstarred-pinned Y is selected moves selection Y→X and drops Y's pin mid-triage — the user didn't "leave" Y in any intentional sense. Gate the drop on intent: fire for `.browse`/`.click`/`.explicitOpen` (and selection→nil), skip `.restoreFocus`. `.autoAdvance` is arguable but fine to allow (user acted on another row). The intent is available at exactly the hook site, so this is cheap — but it tensions with HIGH-1 (direct-binding sets have no intent; `consumeSelectionIntent` defaults those to `.click`, which is the right default for dropping).

**LOW-1 — Pin-time restriction for bulk unstar is a no-op as written.**
Step 2's last paragraph: "only pin ids that are currently selected or checked" — but `toggleStarChecked` (:4362) targets *are* the checked set by definition, so this restricts nothing. Delete the paragraph; MEDIUM-2's uncheck hook is the real mechanism.

**LOW-2 — Policy helper should inherit the committed-search masking caveat.**
Prior review LOW-1 (still open): `starStateFilterActive` consults chips even when a committed `/` search replaces them. The new policy fn will reproduce this — hide chips + committed plain search would compute `.thread` for a gate that isn't applied. Mostly harmless (drops pins that don't matter), but since you're writing a fresh pure helper, take `committedSearchActive` as an input and mask chips/view gates under it. Cheap to do now, annoying to retrofit.

**LOW-3 — Reload snapshot race.**
`reloadThreads` snapshots `starStateKeepIds` at :1980 before the async fetch; a pin dropped after an in-flight snapshot can transiently re-show the row. Existing pattern, self-healing — just call `reloadThreads()` after a drop batch and accept it.

## 2. Answers to the open questions

1. **Browse vs open:** drop on `selectedThreadId` leave, not `openedThreadId`. Consistent with archive-advance semantics (list row can vanish while pane lags), simpler, and `openedThreadId` intentionally lags during j/k coalescing (:284–286) — keying off it makes the exit timing feel nondeterministic. Pair with the MEDIUM-3 intent gate.
2. **Multi-select:** yes — keep while `id == selectedThreadId || checkedThreadIds.contains(id)`; drop on uncheck and on `clearCheckedThreads`. Requires MEDIUM-2's hook.
3. **starredOnly + hide → session:** confirm. You're in a star-gated list; unstar-then-vanish-on-j would break batch star triage, the exact scenario 5ada495 shipped for.
4. **Optimistic hide leave in scope:** yes, include it (see MEDIUM-1). The pure `ThreadListOptimistic`-style helper + hostless test pattern is already established; the risk is low and without it the feature is "row leaves ~140ms later," which reads as flicker, not triage.

## 3. Verdict

**APPROVE WITH CHANGES:**

1. Move the drop hook to the `selectedThreadId` setter / `listFocus` didSet, or explicitly audit + funnel all binding sites (HIGH-1).
2. Promote step 3 to required (MEDIUM-1).
3. Add uncheck/clear-checked drop hook; delete the no-op bulk-pin restriction (MEDIUM-2, LOW-1).
4. Exempt `.restoreFocus` from triggering drops (MEDIUM-3).
5. Policy helper takes `committedSearchActive` and masks chip/view gates under it; session checked before thread (LOW-2).

## 4. Implementation order

1. **Pure policy helper + tests** — `StarStickinessPolicy` with inputs (view, chips, saved-view fields, search, committedSearchActive); matrix test per plan §5.1 including both-gates→session and search-masking cases.
2. **Pure drop-decision helper + tests** — given (keepIds, oldSelected, newSelected, checkedIds, intent, policy) → ids to drop. Hostless, covers Q1/Q2 edges before touching MailStore.
3. **Wire the hook** at the selection setter level (HIGH-1), plus uncheck/clear-checked sites; call `reloadThreads()` after non-empty drops.
4. **Optimistic hide leave** — extend the inbox branch of `threadLeavesCurrentList` (or a `ThreadListOptimistic.leavesHiddenCategory` helper) with unstarred + hidden-category + not-in-keepIds; hostless tests mirroring `CategoryHide` semantics (denorm flags for promo/social, `labelIds LIKE` for Updates/Forums — keep them in sync).
5. **Integration pass:** verify archive/trash of a pinned row still removes (existing :4037–4041 path), session policy unchanged in Starred/is:starred, `make test`, then Fable re-review.
