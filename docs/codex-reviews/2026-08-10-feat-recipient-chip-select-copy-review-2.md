---
date: 2026-08-10 20:06
kind: fable-review
target: branch feat/recipient-chip-select-copy vs main
verdict: SHIP
reviewer: Fable (jacq-claude, model=claude-fable-5, effort=low)
job_id: review-20260810T200513-17519
reviewed_commit: e2da456429c2029c9a9684a428cb543f9a94d1b4
requested_model: claude-fable-5
resolved_model: claude-fable-5
effort: low
invoked_from: /Users/ronboger/mishmail/.worktrees/recipient-chip-select-copy
git_branch: feat/recipient-chip-select-copy
focus: re-review after pass-1 polish fixes
---

# Fable Review Pass 2 — recipient chip select + copy

## Prompt

Re-review the complete diff against main after addressing pass-1 findings.

## Verbatim Fable review

Permission deny rule "MultiEdit" matches no known tool — check for typos.
# Re-review: recipient chip select + copy (vs main)

All pass-1 fixes verified present in the diff: `ForEach(..., id: \.element)` (AddressField.swift:223), hover clear + clamp in `onChange(of: tokens.count)` (:247-253), selection-owns-cut (`handleBackspace` checks selection before `draftIsEmpty`, TokenAddressEditing.swift), forward-delete gated on existing selection (AddressField.swift keyCode 117 branch), `;:@` in `needsDisplayNameQuotes`, case-insensitive lookups in both `displayName` and the monitor's `nameForEmail`.

## Findings

**Medium — Cmd+C/Cmd+X hijack a mouse-made text selection in the draft.**
`handleKeyDown` (AddressField.swift:392-412) consumes Cmd+C/X whenever `keyboard.selection != nil`, regardless of draft state. Chip selection is cleared on *typing* (`onChange(of: draft)`), Escape, focus loss, and chip actions — but not on a mouse click into the text field. Scenario: select a chip with ←, click into the draft, select existing draft text with the mouse (draft string unchanged, so `onChange` doesn't fire), press Cmd+C → you copy the chip, not the highlighted text; Cmd+X additionally deletes the chip. Gmail drops chip selection on any click into the field. Fix: clear `keyboard.selection` on mouse-down in the field (e.g. a `.leftMouseDown` case in the monitor, or an `onTapGesture` on the TextField).

**Low — Cmd+Shift+C / Cmd+Shift+X are also captured.**
The Cmd branch excludes `.option`/`.control` but not `.shift` (AddressField.swift:392-394). With a chip selection active, Cmd+Shift+C (a common "copy link/style" shortcut elsewhere) is swallowed as a plain copy. Add `!shift` to the guard or restrict to exactly `.command`.

**Low — Escape may never reach `.onKeyPress(.escape)`.**
Every other selection key had to move to the NSEvent monitor because "the field editor eats them" (comment at AddressField.swift:208-210), yet Escape-to-clear is implemented via `.onKeyPress(.escape)` (:274). NSTextView typically consumes Escape for `cancelOperation:`/completion. If it's eaten, there's no keyboard way to deselect other than typing or →. Unverified — worth one manual check; if it fails, handle keyCode 53 in the monitor. 

**Low — Cmd+C with a stale/empty selection swallows the event silently.**
If `emails` resolves empty (selection indices out of range), the branch still `return nil` (:399-411), so the user's Cmd+C does nothing at all instead of falling through to the field editor. Clamping makes this hard to reach; returning `event` when `emails.isEmpty` would be safer.

**Info — display names containing `.` aren't quoted** (`Ron B. Jr. <a@x.com>`). Dot is not atext per RFC 5322, though universally tolerated as obs-phrase. Fine to leave.

## Test coverage

Good on the pure logic (backspace outcomes, move/extend/clamp, clipboard quoting/joining). Gaps, all minor: no test for shift-extend right past the last chip (stays put), none for `removeSelected`/`handleBackspace` with an out-of-range selection, and the Cmd-branch behavior in `handleKeyDown` is untestable as written (static but takes `NSEvent`) — the mouse-selection finding above lives there.

## Open questions

- Should a plain mouse click in the draft clear chip selection (Gmail does)? That single change resolves the Medium finding.
- Was Escape-to-deselect verified in the running app?

## Verdict

**SHIP** — the Medium finding is an edge interaction (mouse text-select while a chip selection lingers), everything else is polish. Recommend the mouse-down clear as a fast follow.

Not verified by running: I reviewed the diff only; tests were not executed in this read-only session.
