---
date: 2026-07-29 14:41
kind: review
target: branch fix/compose-footer-send-gi vs main
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260729T143739-57014
reviewed_commit: 7e21e74c9299cdb1a8372c9c7e0d5b4ef8763bea
invoked_from: /Users/ronboger/mishmail/.worktrees/compose-footer-send-gi
git_branch: fix/compose-footer-send-gi
git_head: 7e21e74c9299cdb1a8372c9c7e0d5b4ef8763bea
focus: re-review after identity-guarded close + abortFinish focus
---

# Prompt

Re-review after addressing NOT READY findings. Check the identity-guarded close(), abortFinish focus restore, and left-cluster contentShape. Confirm the original task is fixed and finish with SHIP or NOT READY.

# Verbatim review

id:	review-20260729T143739-57014
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/compose-footer-send-gi
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260729T143739-57014/output.log
---
## Re-review: compose footer clipping + post-Send `g i` (branch `fix/compose-footer-send-gi` vs `main`)

### Previously flagged NOT READY items — all verified fixed

1. **Identity-guarded `close()`** ✓ — `ComposeView.swift:152-162`: `guard store.composeRequest?.id == request.id else { return }` before `clearComposeRequest()`. This is checked against the right identity: the view is keyed with `.id(request.id)` at `ContentView.swift:512`, so a new compose opened during the finish window mounts a fresh view and the stale finish task's `close()` no-ops instead of yanking the new card. `openCompose` / `clearComposeRequest` / sign-out all reset `composeFinishing` (`MailStore.swift:1099, 1148, 1530`), so the flag can't leak across requests.

2. **`abortFinish()` focus restore** ✓ — `ComposeView.swift:136-146`: `didFinish = false`, `composeFinishing` cleared only when this card is still the mounted request (correctly avoids clobbering a newer compose), and `focusBody()` puts the caret back so the re-enabled card is usable. If the card was replaced, `focusBody()` writes to an unmounted view's `@FocusState` — a no-op, harmless.

3. **Left-cluster `contentShape`** ✓ present — `.contentShape(Rectangle())` + `.clipped()` + `layoutPriority(0)` on the left cluster; right cluster `.fixedSize(horizontal: true)` + `layoutPriority(1)`. This is the correct priority split for the original clipping bug. `ComposeFooterLayoutTests.swift` pins the contract, including the default-width regression case (620 − 28 inner width fits a ~220pt right cluster).

### Original task confirmed fixed

- **Footer clipping**: right cluster (trash + reserved-width status + Send/schedule) is fixed-size at priority 1; left tools shrink and clip first. The topLeading frame + clipShape at `ContentView.swift:515-517` can no longer cut the trailing edge at default widths.
- **Post-Send `g i`**: `beginFinish()` (`ComposeView.swift:120-133`) resigns focus, dismisses sheets/pickers, sets `composeFinishing`; all four `ContentView` key gates (Esc ladder ~698, chord pass-through ~746, ⌘↩ ~764, single-key ~962) route through `ComposeKeyOwnership`, so `g i` reaches the mailbox during the finish window instead of typing into a locked body. `send()`/`scheduleSend()`/`saveAndClose()`/`discardAndClose()` all go through `beginFinish` with re-entrancy guard. `.disabled(didFinish)` (`ComposeView.swift:1147`) locks the form.

### New findings (all LOW)

1. **LOW — `.clipped()` doesn't clip hit-testing.** `ComposeView.swift:~1101-1107`: the comment claims `contentShape + clipped` keep overflow icons "from receiving clicks", but in SwiftUI `.clipped()` is visual-only and `.contentShape` on a container doesn't constrain child `Button` hit areas. Visually-clipped format-bar buttons can still take clicks in the flexible gap beside the right cluster. Send/status are safe (later sibling → hit-tested on top). Practical exposure is small (only very narrow cards). Fix if desired: wrap the left cluster's overflow in a `GeometryReader`-gated `allowsHitTesting(false)`, or accept and correct the comment.

2. **LOW — header stays interactive mid-finish.** `.disabled(didFinish)` covers only `expandedBody`; `expandedHeader` (minimize, split toggle, tap-to-minimize at `ComposeView.swift:695-713`) still works while a finish awaits persist. Close ✕ is safe (`beginFinish` guard), and minimizing mid-finish just collapses a card about to unmount — cosmetic inconsistency with "the card reads as non-interactive."

3. **LOW — narrow content-loss window on abort-after-replacement.** If a finishing card is replaced (`g i` → new reply) and the finish then aborts (`buildPendingSend` fails, e.g. attachment read error at `ComposeView.swift:1877`), the old card's `onDisappear` already skipped `saveDraftIfNeeded()` because `didFinish` was true (`ComposeView.swift:556`) — the tail typed since the last autosave is lost. Requires attachment failure + replacement inside the persist window (empty-To can't trigger it since `cannotSend` disables Send). Acceptable; noting for completeness.

### Open questions

- None blocking. Tests could not be executed in this read-only session (`make test` requires approval); the two new test files are pure-logic XCTest and match the shipped helpers' signatures, and both helpers are registered in `project.yml`.

### Verdict

**SHIP.** All three NOT READY items are correctly addressed, the original footer-clipping and post-Send `g i` behaviors are fixed with tested pure-logic contracts, and the remaining findings are low-severity polish items that don't warrant blocking.
