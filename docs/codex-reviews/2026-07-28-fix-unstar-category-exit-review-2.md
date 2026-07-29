---
date: 2026-07-28 23:08
kind: review
reviewer: Fable (jacq-claude, claude-fable-5)
target: branch fix/unstar-category-exit vs main (commit cbebfc7)
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260728T230542-37364
reviewed_commit: cbebfc7db5863a81343b03284944025147d4cc22
invoked_from: /Users/ronboger/mishmail/.worktrees/unstar-category-exit
git_branch: fix/unstar-category-exit
focus: >
  Re-review after pass-1 LOWs: empty keepIds early-return; no orphan pins on
  unselected unstar; remove no-op checked scrub.
---

# Re-review: category-hide unstar thread-long exit (branch `fix/unstar-category-exit` @ cbebfc7)

**Scope note (important):** the merge-base with `main` is `b251841`. The `git diff main` output includes an apparent *revert* of `25eba43` ("Fix inbox badge for hidden Updates/Forums; grid category picker" — `SidebarCounts.swift`, `ThreadListView.swift` CategoriesPopover, `ThreadDenormTests`), but those are just main's newer commits not on this branch. The actual branch work is `b251841..cbebfc7`, and I reviewed that. **Do not merge without rebasing onto main first** — otherwise the review docs from `main` (`f946877`) will conflict, and a naive squash-against-main would regress the badge fix.

## Findings

### MEDIUM

**M1. Branch is behind main; both sides edit `MailStore.swift`.** `main`'s `25eba43` added `inboxBadgeHideCategories` and threaded `hideCategories` through `fetchSidebarCounts` call sites; this branch edits nearby regions (reload path is adjacent). Hunks look non-overlapping so the merge will probably be clean, but the combined semantics deserve one post-rebase check: after rebase, `applyThreadLongStarPinDrops`'s optimistic `threads.removeAll` (MailStore.swift:1370-1380 on this branch) does **not** adjust sidebar unread counts the way `applyOptimisticCountDelta`/`SidebarCounts.memberships` paths do — a dropped unread hidden-category row leaves the list but the badges reconcile only on the next coalesced DB reload. Same-frame badge consistency was the whole point of `25eba43`. Likely acceptable (reconciliation is the source of truth), but verify after rebase.

### LOW

**L1. Stale `pendingSelectionIntent` window** — `MailStore.swift:283-292`. The setter reads `pendingSelectionIntent` but doesn't consume it; `ContentView.swift:126` consumes it in `.onChange`, which fires on the next SwiftUI pass. Two synchronous selection changes before `onChange` runs would let the second write see the first's intent. Concretely: `restoreSelectionFocus` (`.restoreFocus`, exempt from drops) followed synchronously by any direct `selectedThreadId =` write would wrongly skip the drop. I found no current call site that does this — all paths go through `selectThread`/`setSelectionFocus`, which overwrite the intent first — so this is latent, not live. A `defer`-style one-shot read in the setter would close it.

**L2. Pin-drop row removal vs. `leavesOptimistically` hide-set asymmetry.** `applyThreadLongStarPinDrops` uses `effectiveCategoryHide` (decodes saved-view chipsJSON, MailStore.swift:1327-1341), while the new branch in `leavesOptimistically` (MailStore.swift:4186-4196) uses live `chips.category.hide` — correct for its `.inbox/.account` case only, and saved views take a different `leavesOptimistically` path, so no live bug. Just note the two hide-set sources must stay in sync if saved views ever share the inbox case.

**L3. `checkThread` shift-range path calls the drop pass while *adding* checks** (MailStore.swift:1257). Adding checks can only retain more pins, never orphan any — the call is harmless but pure overhead (guarded by the empty-pin early return, so negligible). The genuinely needed call sites are the uncheck branches and `clearCheckedThreads`.

### Pass-1 LOW resolutions — verified

- **Empty-pin early return**: `guard !starStateKeepIds.isEmpty` (MailStore.swift:1352) correctly short-circuits before policy resolution and saved-view JSON decode on key-repeat j/k. ✓
- **No orphan pins**: `pinStarStateKeep` (MailStore.swift:4076-4080) runs an immediate drop pass under `.thread` policy, so unstarring a non-selected, non-checked row leaves at once instead of leaving a pin armed for an unrelated later selection change. Covered by `testUnselectedUnstarDropsImmediatelyUnderThreadPolicy` (StarStickinessPolicyTests.swift:950). ✓
- **`checkedThreadIds` scrub removal**: no stray scrub remains; check/uncheck paths route through the shared drop pass. ✓

### Correctness spot-checks (all pass)

- All selection mutations funnel through the `selectedThreadId` setter: List binding → `selectThread(intent: .click)` (ThreadListView.swift:52-56), keyboard/auto-advance → `setSelectionFocus` (MailStore.swift:3823-3831, 4153). Single drop site holds.
- `.restoreFocus` exemption (StarStickiness.swift:488-493) protects Undo re-select; `restoreSelectionFocus` uses it (MailStore.swift:4085).
- Session-over-thread precedence, search-masks-chips, `label:starred` case-insensitivity, legacy `excludePromotions`, and promo/social denorm vs. `labelIds LIKE` parity all match production query semantics and are test-covered (261-line policy test file; matrix is thorough).
- Archive/trash still remove via the unchanged `leavesInboxList` check running *before* the new category-hide branch; no auto-archive is introduced on unstar (unstar only mutates STARRED).
- `idsToDrop` retains selected + checked ids; drop under `.session` is always empty, so Starred/is:starred/starredOnly stickiness remains session-long. ✓

## Open questions

1. Intentional that **deselecting** (Esc → `selectedThreadId = nil`) drops the pin and yanks the row? It fits "selection leaves the thread" literally, but a user hitting Esc to glance at the list may be surprised. (Behavioral choice, not a bug.)
2. Rebase-onto-main timing — before or after this SHIP is recorded?

## Suggested fixes (not applied — read-only)

- L1: consume the intent in the setter (`defer { pendingSelectionIntent = nil }` inside the drop branch) or snapshot-and-clear, keeping `consumeSelectionIntent()` parity for ContentView.
- L3: move the `applyThreadLongStarPinDrops` call in `checkThread` to only the uncheck branch.

## Verdict

**SHIP** — the branch's own changes are correct, well-factored (pure `StarStickiness` helpers with strong hostless coverage), and resolve both pass-1 LOWs as claimed. Condition: rebase onto `main` (M1) before merging so the `25eba43` badge work isn't clobbered, and give the badge-vs-optimistic-drop interaction one manual look post-rebase.
