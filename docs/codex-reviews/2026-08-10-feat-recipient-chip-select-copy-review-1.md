---
date: 2026-08-10 20:03
kind: fable-review
target: branch feat/recipient-chip-select-copy vs main
verdict: SHIP
reviewer: Fable (jacq-claude, model=claude-fable-5, effort=low)
job_id: review-20260810T200059-15135
reviewed_commit: 0ae2d7c375a0c3a1cff290a997abd12a1b99cc13
requested_model: claude-fable-5
resolved_model: claude-fable-5
effort: low
invoked_from: /Users/ronboger/mishmail/.worktrees/recipient-chip-select-copy
git_branch: feat/recipient-chip-select-copy
focus: Gmail-style recipient chip select + copy Name <email>
---

# Fable Review Pass 1 — recipient chip select + copy

## Prompt

Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: In compose mode, when recipients are in To/Cc/Bcc as chips showing display names (e.g. Josh Yang), Shift+Backspace / Backspace / ← should select/highlight chips so the user can copy them. Copy should produce Gmail/Superhuman format: Josh Yang <josh@glyphic.bio>. Second Backspace deletes the selection. Research target was Gmail/Superhuman recipient chip selection + clipboard format.

## Verbatim Fable review

Permission deny rule "MultiEdit" matches no known tool — check for typos.
Ran the unit suite: `xcodebuild test -scheme MishMailTests -only-testing:…/TokenAddressEditingTests` — **34 tests, 0 failures**.

# Review: recipient chip select + copy (0ae2d7c vs main)

## Findings

**Medium**

1. **`ForEach` identity changed from `\.self` to `\.offset`** — `AddressField.swift:54`. With offset identity, deleting a middle chip makes SwiftUI reuse rows by position: chip N+1's view inherits chip N's identity, so transient per-row state (`hoveredToken` chrome, button hover, animations) can attach to the wrong chip after a mid-list delete. Tokens are deduped, so the old `id: \.self` was already unique and index can be threaded via `enumerated()` while keeping `id: \.element`. Not a correctness bug in outcomes, but a regression risk in hover/animation behavior that the old code deliberately handled (`clearChipHoverChrome` comments).

2. **`clearHover` in the key monitor is a stubbed no-op** — `AddressField.swift:269-271`. When Backspace/Cmd+X deletes a chip that the pointer is over, the "stuck pointing-hand" bug the codebase explicitly guards against elsewhere (`clearChipHoverChrome`, `AddressField.swift:243-249`) can occur. The × button path clears it; the keyboard path doesn't. The View's `clearChipHoverChrome` could be invoked via the same trick used for selection (move `hoveredToken` into `ChipKeyboardState`, or clear hover in `.onChange(of: tokens.count)`).

3. **Cmd+X with a selection but non-empty draft copies without cutting** — `AddressField.swift:319-323`. `applyBackspace` gates on `draftEmpty`, so if a selection ever coexists with draft text, Cmd+X silently degrades to copy. Today `onChange(of: draft)` clears the selection, so it's likely unreachable — but the invariant is enforced only in the View layer, not where cut happens. A defensive `handleBackspace` call ignoring `draftIsEmpty` for the selection branch (selection implies chip context) would close it.

**Low**

4. **Forward-delete (keyCode 117) selects the *last* chip** — `AddressField.swift:327`. It's routed through the same `handleBackspace` as Backspace, so with an empty draft, forward-delete highlights the last chip. Gmail's forward-delete at the draft position does nothing (chips are before the caret). Cosmetic deviation from the researched behavior.

5. **`needsDisplayNameQuotes` misses `;`, `:`, `@`** — `TokenAddressEditing.swift:188-192`. A name like `Team: Infra` or `ron@home` pastes unquoted; `;` is a recipient separator in Outlook and `:` opens RFC 5322 group syntax, so a paste target could mis-split. Comma/quote/angle (the common cases) are covered. Adding those three chars to the set is cheap.

6. **`nameForEmail` matches contacts by case-sensitive email equality** — `AddressField.swift:264-266`. If a chip was committed as `Josh@Glyphic.bio` but the contact stores lowercase, copy falls back to the bare email instead of `Josh Yang <…>`. Depends on whether commit normalizes case (didn't verify); a `caseInsensitiveCompare` match would be safer.

7. **Transient double-monitor window when focus moves To→Cc** — pre-existing pattern, but the monitor now consumes more keys (arrows, Cmd+C), so a momentarily-stale monitor from the blurring field has more chances to swallow an event meant for the newly focused field. `onChange(of: focused)` ordering makes this unlikely in practice.

## What's solid

- The stale-`@State`-capture trap in the old monitor is correctly fixed by capturing `Binding`s + the `@Observable` reference box (`AddressField.swift:255-259`); the doc comment explains why.
- `removeSelected` iterates high→low; `clampedSelection` runs on `tokens.count` change; every draft-mutating path (`accept`, `beginEdit`, ×-click, typing, blur, Escape) clears the selection.
- Monitor teardown exists on both blur and `.onDisappear` (`AddressField.swift:175-177`).
- Test coverage of the pure logic is good: select-first-then-delete, range extend, edge clamping, clipboard quoting/escaping, multi-join. Requested format `Josh Yang <josh@glyphic.bio>` is tested verbatim.

## Open questions

- Cmd+A to select all chips (Gmail supports it) — intentionally out of scope?
- Should ← at caret position 0 of a *non-empty* draft enter chip selection (Gmail does)? Current code only enters selection when the draft is empty. May be intentional since caret position isn't observable from the monitor.
- Paste of `Name <email>` back into the field — does the commit path parse that format? Round-tripping a copy into another MishMail field wasn't part of this diff and I didn't verify it works.

## Suggested fixes (not applied)

- `ForEach(Array(tokens.enumerated()), id: \.element.self)` (or a wrapper struct) to restore stable identity.
- Route hover-clear through `ChipKeyboardState` or `.onChange(of: tokens.count)`.
- In the Cmd+X branch, delete based on selection presence rather than `draftEmpty`.
- Exclude keyCode 117 from the select-last path (only allow it to delete an existing selection).
- Add `;:@` to `needsDisplayNameQuotes`; make the contact-name lookup case-insensitive.

## Verdict

**SHIP** — core behavior matches the task, logic is tested and passing, and all findings are polish-level; #1 and #2 are worth a fast follow-up.
