---
date: 2026-08-10 20:12
kind: fable-iterate review
review_model: claude-fable-5
review_effort: low
job_id: review-20260810T201255-22904
base: main
branch: fix/split-open-all-messages
reviewed_commit: ae1b756
verdict: SHIP
checks: MessageExpandPolicyTests pass; make test 1400/0
---

# Review — side-by-side open-all messages (pass 3, final)

id:	review-20260810T201255-22904
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/split-open-all-messages
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260810T201255-22904/output.log
---
Permission deny rule "MultiEdit" matches no known tool — check for typos.
**SHIP.** The Medium is fixed correctly and the branch (4 commits, `ec4780f..ae1b756` vs main) is sound. All 7 `MessageExpandPolicyTests` pass (ran `xcodebuild test -only-testing:MishMailTests/MessageExpandPolicyTests`).

## Findings

**Medium fix verified — no regression path.** `ThreadDetailView.swift:756-798`: `priorIds` is captured from `messages` *before* `ThreadRefresh.merge`, so `arrived = live.subtracting(priorIds)` is exactly "ids new this merge". A user-collapsed card's id stays in `priorIds`, so background sync and draft-suppression refreshes no longer re-open it. Pruning to `live` before the union also handles send/discard renumbering. The `wasEmpty` branch (superseded initial `.task`) correctly falls back to the full seed via `seedExpandedMessagesIfNeeded()`.

**Low — last-card onAppear can undo a collapse-all** (`ThreadDetailView.swift:2055-2060`). In split mode, if the user collapses every card and the last card later re-fires `onAppear` (LazyVStack recycling on scroll), `expandedMessageIds.isEmpty` is true and it re-opens itself. Same shape as the pre-existing single-mode fallback; cosmetic.

**Low — newly arrived messages skip attachment/CID recovery** (`ThreadDetailView.swift:793-796`). The refresh path calls `loadBodyIfNeeded` for `arrived` ids but not `recoverAttachmentsIfNeeded`/`resolveCIDImagesIfNeeded`, which the seed path does (`ThreadDetailView.swift:1001-1005`). Matches prior single-mode refresh behavior, so not a regression — inline images in messages arriving mid-split may need a manual re-expand.

**Low — draft-to-sent same-id edge**. `priorIds` includes draft ids while `live` excludes them; a message whose id survives a draft→sent transition wouldn't auto-open. With Gmail, send assigns a new id, so this is theoretical.

The `ContentView.swift` split-layout change (NavigationStack wrapper so toolbar items mount, `allowsHitTesting(false)` spacer) is straightforward. The `AddressField`/`TokenAddressEditing` deletions in the raw diff are just main having moved ahead with the chip feature — not part of this branch.

## Open questions

- None blocking. The two Low hydration/onAppear items are worth a follow-up only if users report them.

## Suggested fixes (not applied)

- After `formUnion(arrived)`, also call `recoverAttachmentsIfNeeded(id:)` and `resolveCIDImagesIfNeeded(id:)` per arrived id.
- Guard the last-card `onAppear` fallback with a "user has interacted" flag so collapse-all sticks in split mode.
