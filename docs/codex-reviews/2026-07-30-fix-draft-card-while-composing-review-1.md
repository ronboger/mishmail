---
date: 2026-07-30 17:45
kind: fable-review
target: branch jacq-claude/fix-draft-card-while-composing vs main
verdict: NOT READY
reviewer: Fable (jacq-claude, model=claude-fable-5, effort=low)
job_id: review-20260730T174121-66249
reviewed_commit: c398595d3ffed5db972ff4b0d2a101bd77991895
invoked_from: /Users/ronboger/mishmail
git_branch: jacq-claude/fix-draft-card-while-composing
focus: hide draft card while composing; mute draft preview chrome
---

# Fable Review Pass 1 — hide draft card while composing

## Prompt

Review the complete diff against the requested task: (1) when user continues/edits a reply draft, hide DraftMessageCard and long-thread draft banner for that draft so compose and the orange card don't both show; (2) mute/gray draft preview chrome so unsent drafts don't look like real messages. Check correctness (including replacingDraft id chain after autosave, multi-request ownership, no breakage of suppressedDraftMessageIds undo-send), regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

## Verbatim Fable review

# Review: hide draft card while composing + mute draft chrome (vs `main`)

## Findings by severity

### Medium

**M1. Late autosave from a replaced compose card resurrects a stale claim → draft card hidden for the rest of the session.**
Order of operations when a compose card is unmounted *without* an explicit exit (a new compose/reply request replaces it — the exact scenario the `onDisappear` comment describes):

1. `ComposeView.swift:571` — `onDisappear` fires `saveDraftIfNeeded()` (async, `didFinish == false`).
2. `ComposeView.swift:574` — `endComposingDrafts(requestId: request.id)` removes the old request's entry.
3. The fire-and-forget persist later succeeds and hits `ComposeView.swift:449` — `store.noteComposingDraft(saved.id, requestId: request.id)`.

Step 3 re-creates `composingDraftIdsByRequest[request.id]` for a request whose card is gone and will never call `endComposingDrafts` again (`MailStore.swift:5096-5100` only removes by requestId). Result: the just-saved draft's `DraftMessageCard` and the long-thread banner are permanently suppressed (until app restart), and the union in `composingDraftMessageIds` (`MailStore.swift:5085`) leaks the stale set forever. Note this is *not* covered by `didFinish` guards at `ComposeView.swift:420/443` — `didFinish` is false on the replacement path by design.

Suggested fix (do not apply): guard the note at `ComposeView.swift:449` with `if store.composeRequest?.id == request.id` (matching the pattern used by `abortFinish()` at `ComposeView.swift:146` and `close()` at `:165`), or make `MailStore.noteComposingDraft` ignore requestIds that don't match the active `composeRequest`.

### Low

**L1. Banner tap can target the already-composing draft.** `showsDraftBanner` (`ComposingDraftVisibility.swift:26-30`) shows the banner when *any* live draft isn't composing, but the banner's action (`MailStore.editDraft(inThread:)`, `MailStore.swift:5104`) opens the *newest* draft. If the newest draft is the one already open in compose and an *older* sibling justified the banner, tapping it re-opens the compose you're already in (replacing the request) instead of the older draft. Edge case (two live drafts in one thread), pre-existing pattern, but the new visibility logic makes the mismatch reachable.

**L2. No cleanup of `composingDraftIdsByRequest` on signout/account removal.** Session-scoped, ids are namespaced (`account:draftId`), so worst case is a hidden card in a re-added account within one session. Negligible, noting for completeness.

**L3. Test gap around the actual bug surface.** `ComposingDraftVisibilityTests.swift` covers the pure helper well (including sibling drafts and the autosave-chain set), but the request-keyed ownership lifecycle in `MailStore` (`noteComposingDraft` / `endComposingDrafts` / multi-request overlap / the M1 late-save race) is untested — and that's where the only real bug lives. A small MailStore-level test simulating note → end → late note would have caught M1.

## Verified-correct points

- **Autosave id chain**: `onAppear` registers both `editingDraft?.id` and `replacingDraft?.id` (`ComposeView.swift:543-544`), and each successful autosave adds `saved.id` (`:449`); ids accumulate per request, so the card can't blink back mid-typing. Matches the test at `ComposingDraftVisibilityTests.swift:23-29`.
- **Multi-request ownership**: keying by `request.id` correctly handles SwiftUI's new-appear-before-old-disappear overlap — the new card's claim survives the old card's `endComposingDrafts`. (Undone only by M1's late write.)
- **Undo-send untouched**: `suppressedDraftMessageIds` / `PendingDraftVisibility` paths are not modified; the new mechanism is render-time only (rows stay in payload), so Discard-from-card and undo-send restore behave as before. Restore path claims `request.restore?.replacingDraft` via `:544`, so the restored draft's card is hidden during the restored compose.
- **Discarded drafts unaffected**: the hide only wraps the `DraftMessageCard` branch (live drafts); DRAFT+TRASH still renders `MessageCard` (`ThreadDetailView.swift:199-213`).
- **Build wiring**: `ComposingDraftVisibility.swift` added to the app target (`project.yml:211`) and picked up by the test target's `Tests/MishMailTests` glob plus its own source list entry — tests compile without `@testable`.
- **Chrome muting** (`ThreadDetailView.swift:1241-1270`): sender → `.medium`/`.secondary`, recipients → `.tertiary`, preview → `.secondary`. Consistent step-down, cosmetic-only, no behavior risk.

## Open questions

1. In `saveAndClose()` (`ComposeView.swift:476-482`), `beginFinish()` sets `didFinish = true` before `enqueuePersist`, yet `performPersist` returns early at `:420` when `didFinish` — how does the explicit save-and-close ever persist dirty content? This is pre-existing (not from this diff) but interacts with where `noteComposingDraft` calls can fire; worth confirming intended flow.
2. Is >1 simultaneous compose card possible (split + minimized)? If two requests ever edit the *same* draft, the union semantics are still correct, but the M1 fix should preserve that.

## Verdict

**NOT READY** — M1 is a real, reachable regression (compose-replaces-compose permanently hides the saved draft's card, defeating the feature's own "card returns when compose closes" contract). It's a one-line guard fix; everything else ships as-is.
