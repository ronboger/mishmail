---
date: 2026-08-10 20:09
kind: fable-review
target: branch feat/recipient-chip-select-copy vs main
verdict: SHIP
reviewer: Fable (jacq-claude, model=claude-fable-5, effort=low)
job_id: review-20260810T200917-19948
reviewed_commit: c16115d90d4eafc9520e03b3713bbac4105c3507
requested_model: claude-fable-5
resolved_model: claude-fable-5
effort: low
invoked_from: /Users/ronboger/mishmail/.worktrees/recipient-chip-select-copy
git_branch: feat/recipient-chip-select-copy
focus: final re-review after mouse-down clear fix
---

# Fable Review Pass 3 — recipient chip select + copy

## Prompt

Final re-review after pass-2 medium fix.

## Verbatim Fable review

Verdict: **SHIP.** All four pass-2 fix points are correctly implemented, the pure logic is well-tested (26 tests covering the new behavior), and I found no correctness or security defects. Remaining observations are minor polish, none blocking.

## Verification of the pass-2 fixes

1. **leftMouseDown clears chip selection** — `AddressField.swift:358-366` (monitor now matches `[.keyDown, .leftMouseDown]`, clears selection and passes the event through). Clicks on chip buttons also route through `beginEdit`/remove, which clear selection themselves, so ordering is safe.
2. **Cmd+C/X exact-command only** — `AddressField.swift:404`: `cmd, !shift, !flags.contains(.option), !flags.contains(.control)`. Cmd+Shift+C etc. pass through as required.
3. **Escape in monitor** — keyCode 53 handled at `AddressField.swift:426-429`, only consumed when a selection exists; the `onKeyPress(.escape)` fallback is redundant but harmless.
4. **Empty-selection Cmd+C falls through** — no selection → the Cmd+C branch isn't entered; stale-index selection producing zero emails → `guard !emails.isEmpty else { return event }` (`AddressField.swift:411`). Both paths let the field editor own copy.

## Findings (minor, non-blocking)

- **Non-Latin keyboard layouts miss Cmd+C/X** — `AddressField.swift:406` matches `charactersIgnoringModifiers == "c"/"x"`. On e.g. a Cyrillic layout these are "с"/"ч", so the shortcut falls through to the field editor (copies nothing when draft is empty). Matching keyCode 8/7 as a fallback would fix it. Low impact.
- **Clamped selection can land on an unrelated chip** — `clampedSelection` maps a shrink to the new last index (test at `TokenAddressEditingTests.swift:682-686` confirms (2,4)→(1,1)); after a × click removes a chip the surviving selection may highlight a different address. In practice most mutation paths (`beginEdit`, `accept`, × button, backspace-remove) already clear selection first, so only reachable via external `tokens` mutation. Cosmetic.
- **Cmd+X ignores draft-text selection** — with chips selected and text in the draft, Cmd+X cuts the chips, not the draft selection. Documented intentionally ("Selection presence owns cut", `AddressField.swift:417`); matches Gmail closely enough.
- **Local monitor is app-wide while focused** — leftMouseDown anywhere in the app clears the selection. That's actually the desired Gmail behavior (clicking anywhere deselects), and selection only exists while this field is focused, so no cross-field interference.

## Open questions

- None material. `.single(0)` clamp-at-left-edge and right-past-end behavior are tested and match Gmail.

## Suggested fixes (optional, not applied)

- Add keyCode fallback for Cmd+C/X: `event.keyCode == 8 /* c */ || event.keyCode == 7 /* x */`.
- Consider clearing (rather than clamping) selection in `.onChange(of: tokens.count)` when the change didn't originate from the keyboard path — or leave as is; current behavior is safe.

Note: tests were not run in this read-only pass; the assessment is from the diff and test source. The logic layer is pure and the tests are deterministic, so risk is low.
