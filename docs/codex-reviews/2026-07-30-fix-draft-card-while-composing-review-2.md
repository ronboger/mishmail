---
date: 2026-07-30 17:46
kind: fable-review
target: branch jacq-claude/fix-draft-card-while-composing vs main
verdict: SHIP
reviewer: Fable (jacq-claude, model=claude-fable-5, effort=low)
job_id: review-20260730T174420-68728
reviewed_commit: ab78c5a1b4c5b995ad50303f4e05dfd90d9743af
invoked_from: /Users/ronboger/mishmail
git_branch: jacq-claude/fix-draft-card-while-composing
focus: re-review after M1 fix — hide draft card while composing; mute draft preview
---

# Fable Re-review Pass 2 — hide draft card while composing

## Prompt

Re-review after pass 1 NOT READY. Prior M1 (late autosave re-claims dead requestId permanently hiding draft card) should be fixed: noteComposingDraft now requires active composeRequest.id match + ComposeView guards note; tests for acceptsComposingNote and late-note lifecycle. Also banner/list editDraft(inThread) prefers non-composing sibling. Review complete diff vs main for the task (hide draft card while composing; mute draft preview). Confirm M1 closed. Findings by severity; finish SHIP or NOT READY.

## Verbatim Fable review

# Re-review: hide draft card while composing (vs `main`)

## M1 status: CLOSED ✓

The late-autosave re-claim bug is fixed at two independent layers:

1. **Store-level gate** — `MailStore.noteComposingDraft` (MailStore.swift:5093-5099) routes through `ComposingDraftVisibility.acceptsComposingNote`, which only accepts a claim when `requestId == composeRequest?.id`. A save completing after close (`composeRequest == nil`) or after replacement (different id) is rejected.
2. **Call-site guard** — the autosave completion in ComposeView.swift:449-453 re-checks `store.composeRequest?.id == request.id` before calling `noteComposingDraft` (belt-and-suspenders; the store guard alone would suffice).
3. **Keyed release** — `endComposingDrafts(requestId:)` removes only the unmounting card's own entry, so the new-card-appears-before-old-card-disappears SwiftUI ordering race can't strip the successor's claim. `ComposeView` is a single host keyed by `.id(request.id)` (ContentView.swift:550-551), so `onDisappear` reliably fires on close/replace, and stays mounted while minimized (claim correctly persists — editor is still open).
4. **Tests** — `testNoteAcceptedOnlyForActiveComposeRequest` and `testLateNoteAfterEndDoesNotHideCard` pin exactly the M1 lifecycle.

I also verified `ComposeRequest.id` is `let id = UUID()` (MailStore.swift:1068), so the in-place `var req = composeRequest; …; composeRequest = req` mutations (presentation flips, minimize) preserve identity and can't invalidate claims.

## Findings

**No blocking or major issues.** Minor observations:

- **L1 — `editDraft(inThread:)` fallback can still reopen the composing draft** (MailStore.swift:5111-5118). When the *only* live draft is the one being composed, the `?? newestDraft(inThread:)` fallback returns it anyway, so the list context-menu "edit draft" reopens the same draft in a fresh request. Old view saves on `onDisappear`, but the new compose opens from the local message snapshot, which may lag the autosave `replacingDraft` chain (stale content / dead server id). This is pre-existing behavior, not a regression, and the banner path is now correctly suppressed — noting for completeness. A conceivable alternative: when the only live draft is composing, un-minimize/focus the existing compose instead of falling back.
- **L2 — one-frame gap on open**: the claim lands in `onAppear` (ComposeView.swift:547-549), so editor + card can theoretically coexist for a frame after `openCompose`. Cosmetic; not worth store-side claiming given the request-keyed design.
- **L3 — test target compiles sources directly** (project.yml:211, no `@testable import`) — matches the established pattern for all other Support tests; fine.
- Chrome muting in `DraftMessageCard` (ThreadDetailView.swift:1241-1271) is styling only; the DRAFT+TRASH branch correctly keeps `MessageCard` chrome.

## Open questions

1. Card stays hidden while compose is **minimized** (view stays mounted, claim held). This seems intended — the draft is still "open" — but confirm that's the desired UX for a minimized-for-a-long-time compose in a thread you're re-reading.

## Not run

I did not build/run the test suite (read-only invocation); logic in the new pure enum is trivial and test assertions match it by inspection.

## Verdict

**SHIP** — M1 is closed with defense in depth and lifecycle tests; remaining notes are minor/pre-existing.
