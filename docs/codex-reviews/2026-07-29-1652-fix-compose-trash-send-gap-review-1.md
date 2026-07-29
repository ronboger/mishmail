---
date: 2026-07-29 16:52
kind: review
target: branch fix/compose-trash-send-gap vs main
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260729T165153-53965
reviewed_commit: e74f51d6b2ef9d48a22021b2e6dd19156267ffbe
invoked_from: /Users/ronboger/mishmail/.worktrees/compose-trash-send-gap
git_branch: fix/compose-trash-send-gap
git_head: e74f51d6b2ef9d48a22021b2e6dd19156267ffbe
focus: compose footer trash/Send spacing (reorder status left of trash)
---

# Prompt

Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: Fix weird spacing between trash and Send in compose footer. Previous commit reserved draft-status width between trash and Send to prevent idle→saved reflow, which left a large empty hole when idle. This reorders right cluster to status | trash | Send so trash stays adjacent to Send while keeping reserved status width.

# Verbatim review

id:	review-20260729T165153-53965
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/compose-trash-send-gap
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260729T165153-53965/output.log
---
## Review: `fix/compose-trash-send-gap` vs `main`

**Change:** Reorder compose-footer right cluster from `trash | status | Send` to `status | trash | Send`, keeping the reserved-width status sizer so idle→saved doesn't reflow. Matches the stated task.

### Findings

**LOW-1 — Test is tautological; layout "contract" constants aren't wired to the view.**
`ComposeFooterLayout.rightClusterOrder` and `trashAdjacentToSend()` (`Sources/MishMail/Support/ComposeFooterLayout.swift:26,44-51`) are a hand-maintained mirror of the SwiftUI order in `ComposeView.swift:1087-1104` — nothing derives the view from the constant or vice versa. `testTrashAdjacentToSendNotSeparatedByStatus` (`Tests/MishMailTests/ComposeFooterLayoutTests.swift:7`) asserts a hardcoded array equals a hardcoded array; a future edit reordering the HStack passes the test unchanged. It documents intent but is drift-prone. Consistent with this codebase's existing pattern of doc-constant tests, so LOW, not a blocker. A UI/accessibility-order test (via the existing `draftStatus*` accessibility identifiers) would be the real regression guard.

**INFO-1 — Idle gap moves, doesn't vanish.** The reserved sizer width still exists when idle; it now renders as whitespace between the left tools (which are `.clipped()`, `layoutPriority(0)`) and trash. That's the intended trade — hole absorbed into the flexible middle instead of splitting trash from Send — and the trailing-aligned `ZStack` (`ComposeView.swift:753`) means painted status text correctly hugs trash when active. Correct.

**INFO-2 — Width math unaffected.** `rightClusterFits`/`leftToolsMaxWidth` are order-independent (sum ≈ 220 unchanged); test comment update at `ComposeFooterLayoutTests.swift:61` is cosmetic only. No behavioral regression risk there.

No correctness, security, or state-handling issues — the diff is a pure sibling reorder inside one `HStack(spacing: 10)`; the discard button's action, help text, and the send split-button are byte-identical, just moved.

### Open questions
1. Was the visual result confirmed on macOS (idle + saving/saved/failed states) at the narrow-card width where left tools clip? The reorder changes where clipping pressure lands but tests can't verify pixels.
2. Should status text be leading-aligned now that it's the leftmost cluster item? Trailing (hugging trash) is defensible; just confirming it matches the screenshot intent.

### Suggested fixes (optional, not applied)
- Replace/augment the tautological test with an XCUITest asserting element order via accessibility identifiers, or at least add a comment in `ComposeView.swift` pointing at `rightClusterOrder` so editors know to update both.

## Verdict: **SHIP**

Small, well-scoped, correctly implemented; the only weakness is a documentation-grade test, which matches existing repo convention.
