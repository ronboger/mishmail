---
date: 2026-07-29 14:34
kind: review
target: branch fix/compose-footer-send-gi vs main
verdict: NOT READY
model: claude-fable-5
effort: low
job_id: review-20260729T143451-54464
reviewed_commit: 9ced3cac34f05b9d8508cc7c803f35cac10e3f4c
invoked_from: /Users/ronboger/mishmail/.worktrees/compose-footer-send-gi
git_branch: fix/compose-footer-send-gi
git_head: 9ced3cac34f05b9d8508cc7c803f35cac10e3f4c
focus: compose footer draft-status/Send clip + post-Send g i
---

# Prompt

Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: Fix compose reply footer cutting off draft saved/sending/Send controls. Also fix weird UX when user sent and pressed g i (go-to inbox) while send was finishing.

# Verbatim review

id:	review-20260729T143451-54464
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/compose-footer-send-gi
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260729T143451-54464/output.log
---
# Review: compose footer clipping + post-Send `g i`

Diff reviewed: `main..HEAD` (9ced3ca + predecessors), 8 files, +307/−96.

## Findings

### MEDIUM 1 — Stale finish `close()` can yank a *new* compose opened during the finish window

`ComposeView.swift:1868-1881` (`send()`), `:452-458` (`saveAndClose`), `:472-482` (`discardAndClose`): each spawns a detached `Task { @MainActor }` that ends in `close()` → `store.clearComposeRequest()`, which sets `composeRequest = nil` **unconditionally** (`MailStore.swift:1145-1148`).

This change deliberately re-enables mailbox single keys during the finish window (`ContentView.swift:962-968` via `allowsMailboxKeys`). So now: user hits Send → while `awaitPersistIdle()` is pending (arbitrarily long offline — `enqueuePersist` may be stuck) the user presses `c`/`r` (or clicks the sidebar Compose button, `ContentView.swift:1120-1121`) → `showComposeRequest` mounts a new card and resets `composeFinishing` (`MailStore.swift:1099`) → the old task's `close()` then fires and **nils out the new compose**. The new card unmounts mid-typing; content survives only via the `onDisappear` autosave fallback (`ComposeView.swift:544`), so it degrades to a UX glitch rather than data loss — but it's a regression this diff introduces (previously keyboard compose was blocked in this window; only the mouse path could race).

Suggested fix: make `close()` / `clearComposeRequest` identity-guarded — only clear when `store.composeRequest?.id == request.id` (capture the id before the await).

### LOW 2 — `ComposeFooterLayout` is production dead code; the tests don't test the fix

`ComposeFooterLayout` (`Support/ComposeFooterLayout.swift`) is referenced **nowhere** in `Sources/` — the actual fix is the `.frame(maxWidth:).clipped().layoutPriority(0)` / `.fixedSize().layoutPriority(1)` restructure in `ComposeView.swift:1011-1131`. `ComposeFooterLayoutTests` exercise only the standalone arithmetic (including magic constants like `rightCluster = 220` asserted against nothing in the view), so a future regression of the SwiftUI layout would not fail any test. Either wire the enum into the view (e.g. drive the left cluster's `maxWidth` from it via GeometryReader) or acknowledge the tests are spec documentation, not coverage. Also: `rightClusterFits(...) == false` (narrow-card case, test at `ComposeFooterLayoutTests.swift:23-31`) has no corresponding handling in the view — you rely on `ComposePlacement` clamping, which is fine but unverified here.

### LOW 3 — Clipped left tools remain hit-testable

`ComposeView.swift:1090-1094`: `.clipped()` hides overflow visually but does not clip hit testing in SwiftUI. Format-bar buttons clipped past the frame edge can still receive clicks in any gap not covered by the right cluster (right cluster's own buttons win where they overlap, since drawn later). Add `.contentShape(Rectangle())` on the framed left cluster or `.allowsHitTesting` gating, or accept as cosmetic.

### LOW 4 — `abortFinish()` leaves keyboard focus dead

`beginFinish()` clears `bodyFocused` and resigns first responder (`ComposeView.swift:125-131`). On the empty-To abort path (`send()` → `abortFinish`, `ComposeView.swift:1876`), the card re-enables but nothing restores focus: compose again claims typing (`claimsTyping` true), so mailbox keys are swallowed (`ContentView.swift:962-974` guard fails), yet no text field is first responder — single keys go nowhere until the user clicks. Consider `bodyFocused = true` (or restoring prior focus) in `abortFinish()`.

### INFO — Things checked and OK

- `composeFinishing` is reset on every mount/clear/reset path (`MailStore.swift:1099,1148,1530`) and on abort — no stuck-flag path found.
- Re-entrancy: `beginFinish()` guard prevents double-send from ⌘↩ + click; header ✕ / minimize during finish are no-ops via the same guard.
- Esc mid-finish correctly falls through to mailbox Esc (`ContentView.swift:698-708`) instead of re-queuing save-and-close; split gate `&& !store.composeFinishing` has correct precedence.
- `.disabled(didFinish)` on the expanded body plus focus resignation covers the "typing into a locked body" half of the bug.
- `ComposeKeyOwnershipTests` cover all four flag combinations including the odd minimized+finishing case — good.

## Open questions

1. Is `awaitPersistIdle()` bounded (timeout) when offline? If it can hang for many seconds, Finding 1's window is wide and the card sits disabled indefinitely — is there a spinner/status for that state?
2. Intentional that `beginFinish` uses `NSApp.keyWindow` rather than the compose card's own window? A detached compose/split in a non-key window would not resign.

## Suggested fixes (not applied — read-only)

1. Capture `let finishingId = request.id` before the await; in `close()`, guard `store.composeRequest?.id == finishingId` before `clearComposeRequest()` (or pass the id into `clearComposeRequest(ifCurrent:)`).
2. Either use `ComposeFooterLayout` in the view or trim it to a doc comment; drop the misleading magic-number test.
3. `.contentShape(Rectangle())` + `.clipped()` ordering on the left cluster, or `.allowsHitTesting(false)` on overflow.
4. Restore `bodyFocused = true` in `abortFinish()`.

## Verdict

**NOT READY** — the footer layout and key-ownership work is sound and well-commented, but Finding 1 is a real regression opened by the very keyboard-unblocking this diff adds: a stale finish task can dismiss a freshly opened compose. It's a small, targeted fix (identity-guard the close); with that addressed this ships.
