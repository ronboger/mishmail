---
date: 2026-07-29 01:16
kind: review
target: branch fix/compose-draft-status-size vs main
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260729T011442-68133
reviewed_commit: e861f8de4d2dbbe3e7549824d9f2b70df8a53bbc
invoked_from: /Users/ronboger/mishmail/.worktrees/compose-draft-status-size
git_branch: fix/compose-draft-status-size
git_head: e861f8de4d2dbbe3e7549824d9f2b70df8a53bbc
focus: Draft saved status slightly increases compose box size — reserve footer slot
---

# Prompt

Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: when the client does "draft saved" in compose, it slightly increases the size of the overall box. Fix that layout jump so draft status changes do not reflow/grow the compose footer/card.

# Verbatim review

id:	review-20260729T011442-68133
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/compose-draft-status-size
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260729T011442-68133/output.log
---
## Review: compose footer draft-status layout jump fix (`main...fix/compose-draft-status-size`)

**Diff:** `ComposeView.swift` `draftStatusLabel` rework + new `ComposeDraftStatusLayout.swift` + unit tests + project.yml registration.

### Approach assessment

The fix replaces the idle `EmptyView` (zero width) with a `ZStack` containing a hidden sizer `Text("Draft not saved")` that is always laid out, so idle → saving → saved transitions never change the slot's width, plus a fixed `frame(height: 22)` so the row height never changes. This correctly eliminates the reflow described in the task. The layout mechanics are sound:

- `ZStack(alignment: .trailing)` keeps painted text trailing-aligned next to Send (ComposeView.swift:719).
- Outer `.fixedSize(horizontal: true, vertical: false)` (ComposeView.swift:750) preserves the old per-Text `.fixedSize()` guarantee that the slot can't be compressed into wrapping/truncation.
- All painted labels are character-wise ≤ the sizer, and the sizer *is* the longest label by identity, so no truncation.
- Hidden sizer is `.accessibilityHidden(true)`; painted labels keep their accessibility identifiers, so UI tests keyed on `draftStatusSaving/Saved/Failed` are unaffected.

### Findings

**MEDIUM — Idle state now permanently reserves ~"Draft not saved" width in the footer.** Before, idle contributed 0pt; now the trash/status/Send cluster is always wider by the sizer + `.padding(.horizontal, 4)`. On narrow windows (the exact regime commits 0d8be41/3e84ade were hardening), the incompressible `.fixedSize(horizontal: true)` slot squeezes `ComposeFormatBar` earlier than before. This is arguably the intended trade-off (stability over space), but it's a behavior change at idle, not just during status paint, and there's no evidence in the diff that the narrow-window clamp path was re-verified with the extra ~90pt permanently reserved. Worth a manual check at minimum compose width.

**LOW — `rowHeight = 22` duplicates the Send button's hardcoded height (ComposeView.swift:1063) but nothing links them.** `draftStatusLabel` uses `ComposeDraftStatusLayout.rowHeight`; Send uses a literal `22`. The test `testRowHeightMatchesSendControl` asserts `rowHeight == 22` against another literal, so it can't detect drift if someone changes the Send button's height. Suggested: have Send read the same constant (follow-up, needs write mode).

**LOW — `sizerIsLongestLabel()` uses character count as a width proxy.** The comment acknowledges this. It's currently redundant (the sizer *is* `failedLabel`), and character count ≠ rendered width in general ("Saving…" with ellipsis vs wide glyphs). Harmless today; would give false confidence if labels ever change to e.g. "Draft saved ✓" (13 chars but possibly wider than a 15-char string). A real width comparison would need `NSAttributedString` measurement.

**LOW — Tests are mostly tautological.** `testStatusCopyIsStable` and `testWidthSizerIsLongestVisibleLabel` restate the constants; none exercise the actual layout invariant (footer size unchanged across `draftStatus` transitions). The real guarantee lives only in the SwiftUI structure. A snapshot/geometry test would be the meaningful coverage, but I recognize that's heavier infrastructure than this repo may have.

**INFO — Painted labels dropped their individual `.fixedSize()`.** Covered by the outer `.fixedSize(horizontal: true)` on the ZStack, so no regression — just noting the equivalence was checked.

### Open questions

1. Was the narrow-window compose layout (the subject of the two prior commits on this branch) manually re-checked with the width now reserved at idle? That's the most likely place for an unintended regression.
2. Is a visible-but-empty gap at idle acceptable visually? (Trash icon now sits further left of Send even before typing.) Alternative would be `Color.clear.frame(width: measuredWidth)` — same effect, so the current approach is fine if the visual was reviewed.

### Suggested fixes (not applied — read-only)

- Reference `ComposeDraftStatusLayout.rowHeight` in the Send button's `.frame(height:)` at ComposeView.swift:1063 to make the "matches Send" claim structural.
- Optionally verify narrow-width behavior once and note it in the commit message.

### Verdict

**SHIP** — the fix correctly and idiomatically solves the stated layout jump; findings are hardening/verification notes, not blockers. The one thing I'd do before merging is a quick manual pass at minimum compose width (MEDIUM above).
