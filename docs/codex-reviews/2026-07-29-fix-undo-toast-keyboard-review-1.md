---
date: 2026-07-29 15:09
kind: fable-review
target: branch fix/undo-toast-keyboard vs main
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260729T150650-88062
started_at: 2026-07-29T15:06:50
finished_at: 2026-07-29T15:08:50
reviewed_commit: 0627802c3f2eddd4e43a64b27f43cd27b8bf718d
exit_code: 0
invoked_from: /Users/ronboger/mishmail/.worktrees/undo-toast-keyboard
git_branch: fix/undo-toast-keyboard
---

# Prompt

```
Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: if i press archive/send/etc with keyboard shortcuts, it shows the undo for too long. also i want a keyboard shortcut to undo as well. fix
```

# Review (verbatim)

id:	review-20260729T150650-88062
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/undo-toast-keyboard
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260729T150650-88062/output.log
---
# Review: 0627802 — Shorten undo toast and wire reliable keyboard undo

Scope note: the branch is 1 commit behind `main` (8eaa757). All apparent Greeting/doc removals in a two-dot diff are just that; the actual merge-base diff (`main...HEAD`) is clean and focused: `MailStore.swift`, new `UndoToast.swift`, `ContentView.swift`, new `UndoToastTests.swift`, `project.yml`. No conflicts with 8eaa757 (disjoint files).

## Findings

**Low — ⌘Z monitor branch skips the overlay guards the bare-key path has.** `ContentView.swift:827-840` checks compose ownership and text focus but not `store.showCommandPalette` / `store.showLabelPicker` / `store.editingView`, which the single-key path guards at `ContentView.swift:1006-1013`. With the palette or label picker open and a toast pending, ⌘Z silently performs the mailbox undo behind the overlay. Bare `z` in the same state does nothing — inconsistent.

**Low — "Sending…" toast is clobbered by a subsequent triage action.** `queueSend` (`MailStore.swift:4634`) sets `undoAction` without a dismissal timer (correct, 10s window), and correctly invalidates any stale `undoTimer` at :4633. But the reverse order — send, then archive with `e` — replaces "Sending…" with "Archived" and starts the 3.5s timer; after 3.5s no undo affordance remains even though the send is cancelable for ~6 more seconds (⌘Z is also dead since `undoAction == nil`). Pre-existing on main at 6s; the shorter duration makes the dead zone slightly larger. Not introduced by this branch, but adjacent to it.

**Info — weak coupling in `testDisplayDurationIsShorterThanUndoSendWindow`.** `UndoToastTests.swift:19` hardcodes `10` instead of asserting against `MailStore.undoSendWindow` (`MailStore.swift:4619`). If the send window is ever lowered below 3.5, the test won't catch the inversion it documents.

**Info — `UndoToast.isPresented(_ action: Any?)` is a thin wrapper over `!= nil` typed as `Any?`.** Harmless and it makes the presence-only animation intent testable, but a generic `Optional` overload (or animating on `store.undoAction != nil` directly with the comment) would be tighter. `UndoToast.swift:16-18`.

## Correctness checks that pass

- Duration constant is used at the single call site (`MailStore.swift:4251`); all `offerUndo` variants (archive, spam, trash, snooze, move) inherit 3.5s. Send path deliberately bypasses it — matches the doc comment in `UndoToast.swift:4-5`.
- Presence-only animation (`ContentView.swift:317-319`) fixes the re-slide-on-every-archive issue; label still updates in place.
- ⌘Z guard excludes ⌘⇧Z (redo) and never fires when no toast is pending, so text-field ⌘Z falls through untouched (`store.undoAction != nil` gate at :830). Text-focus + expanded-compose guards mirror the established `ComposeKeyOwnership` pattern, including the mid-finish bypass.
- Removing the SwiftUI `.keyboardShortcut("z", .command)` in favor of the NSEvent monitor addresses the flaky-shortcut motivation; bare `z` was already wired via the pre-existing `.undo` binding (`KeyBindings.swift:51`, `MailStore.swift:3613`) — this branch surfaces it on the button label and help text.
- `project.yml` registers the new source file; new tests use `KeyBindings(defaults:)` with an isolated suite and clean it in `setUp`.
- Tests cover: brief duration, presence-only animation semantics, default `z` binding, rebind honored + stale key released.

## Open questions

1. Should ⌘Z with the command palette / label picker open perform mailbox undo (current behavior) or be suppressed like bare `z`? Either is defensible; today they diverge.
2. Is 3.5s intentionally applied to snooze/move undo too (multi-item moves might warrant longer)? Currently yes, uniformly.

## Suggested fixes (not applied)

- Add `!store.showCommandPalette, !store.showLabelPicker, store.editingView == nil` to the ⌘Z branch at `ContentView.swift:827` for parity with the single-key path.
- Assert `UndoToast.displayDuration < MailStore.undoSendWindow` in `UndoToastTests.swift:19` instead of the literal `10`.
- (Optional, follow-up) In `offerUndo`, consider not replacing a pending-send `UndoAction`, or restoring "Sending…" when the triage toast expires while `pendingSend != nil`.

## Verdict

**SHIP** — the change does exactly what the task asked (shorter toast, reliable ⌘Z chord + discoverable `z`), is well-commented, matches existing key-ownership patterns, and has targeted tests. Findings are minor consistency/hardening items; none block.
