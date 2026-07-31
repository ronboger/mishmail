---
date: 2026-07-31 15:34
kind: fable-review
target: branch fix/address-chip-click-edit vs main
verdict: SHIP (with reservations)
reviewer: Fable (jacq-claude, model=claude-fable-5, effort=low)
job_id: review-20260731T153254-79464
reviewed_commit: 5fbc3b98747c065a0c48bcb614538c439a1d8b63
invoked_from: /Users/ronboger/mishmail
git_branch: fix/address-chip-click-edit
focus: click recipient chips to re-open address for edit; × still removes
---

# Fable Review Pass 1 — address chip click-to-edit

## Prompt

Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: Recipient chips in compose To/Cc/Bcc were remove-only (×). Users should be able to click the email address chip to easily edit it (re-open into the text field for typos/wrong recipient). × still removes. Hover affordance is nice-to-have. Diff is on branch fix/address-chip-click-edit: TokenAddressEditing pure helper, AddressField click-to-edit, unit tests.

## Verbatim Fable review

# Review: fix/address-chip-click-edit vs main

Diff reviewed: `TokenAddressEditing.swift` (new helper), `AddressField.swift` (chip UI), `TokenAddressEditingTests.swift` (9 tests), `project.yml` (test-target source entry). Note: I was not granted permission to run `xcodebuild test`, so tests were reviewed but not executed. The app target compiles `Sources/MishMail` wholesale (project.yml:15), so the new file only needed the test-target entry it got (project.yml:164) — correct.

## Findings

**Medium — NSCursor push without matching pop when a chip disappears under the cursor** — `AddressField.swift:161-164`. `onHover(true)` pushes `pointingHand`; the pop only happens on `onHover(false)`. If the chip is removed while hovered — exactly what both the × button and click-to-edit do — SwiftUI often never delivers the exit callback for the removed view, leaving the pointing-hand cursor stuck until some other push/pop rebalances it. Same path leaves `hoveredToken` stale, so if the same address is re-added (e.g. user clicks-to-edit, presses return unchanged), the new chip can render pre-hovered. Suggested fix: clear `hoveredToken` and `NSCursor.pop()` (guarded) inside `beginEdit` and the remove action, or drop push/pop for a `.onContinuousHover`/`pop-if-pushed` flag.

**Medium — helper's draft-commit path likely never runs as written; real behavior diverges from the tested behavior** — `AddressField.swift:43-47` vs `TokenAddressEditing.swift:24-27`. When the user has pending text and clicks a chip, the TextField first loses focus, firing `onChange(of: focused)` → `commitDraft()` (`AddressField.swift:204-208`), which appends the draft **without** the `!next.contains(cleaned)` dedup the helper has. By the time the Button action calls `beginEdit`, `draft` is already `""`. So `testDoesNotDuplicatePendingDraftAlreadyInTokens` pins behavior the UI probably doesn't exhibit — clicking a chip while the draft duplicates an existing token can still produce a duplicate chip via `commitDraft`. (Ordering of focus-resign vs button-action isn't guaranteed either way, which is worse: behavior depends on event order.) Suggested fix: give `commitDraft` the same `!tokens.contains(cleaned)` guard, or route `commitDraft` through the helper so the two paths can't skew.

**Low — duplicate tokens break the view even though the helper carefully supports them** — `AddressField.swift:31` uses `ForEach(tokens, id: \.self)`; two identical addresses yield duplicate IDs (undefined SwiftUI behavior, console warnings, both chips hover together since `hoveredToken` is the string). The helper's first-match semantics (`TokenAddressEditing.swift:28-30, 37-40`) and `testEditRemovesOnlyFirstDuplicate` imply duplicates are a supported state, but the rendering layer can't represent them. Pre-existing (`removeAll` on main had the same identity problem), so not a regression — but the tests now codify support the UI doesn't have. Either dedup on insert (arguably the better product behavior for an address field) or key chips by index.

**Low — `focused = true` after `beginEdit` may race the focus-resignation from the button click** — `AddressField.swift:214`. Clicking the chip while the TextField is focused resigns focus; setting `focused = true` in the same transaction usually works, but this pattern is flaky on macOS (the `autoFocus` path at line 116 already needed an `asyncAfter` for the same reason). If QA sees the field not re-focusing after chip click, that's why. Consider the same deferred-focus trick.

**Info** — Cursor is not positioned at the end of the restored draft, and text isn't selected — acceptable, but selecting the restored address would make "wrong recipient" replacement one keystroke. Nice-to-have only.

## Open questions
1. Is duplicate-chip support intentional, or should the field dedup on commit? The helper and tests say "supported", the `ForEach` says "unrepresentable".
2. Should clicking a chip while an *incomplete* draft exists really discard the draft (helper doc says yes) — given the focus-loss path already discards it via `commitDraft`, the two agree today, but only accidentally.

## Test gaps
- No test for the interaction that actually happens in the UI (focus-loss `commitDraft` firing before `beginEdit`) — needs a UI test; `Tests/MishMailUITests` exists and the repo has precedent for them.
- No test for `beginEdit` where the clicked token equals the pending draft.
- Unit tests were not executed in this review (permission denied); run `xcodebuild test -project MishMail.xcodeproj -scheme MishMailTests` before merging.

## Verdict

**SHIP** (with reservations). The feature works for the mainline case, the helper is clean and well-tested for what it models, and nothing here regresses × removal (first-match removal is actually an improvement over main's `removeAll`). The two Medium findings are real but low-blast-radius polish items — cursor stuck-state and a duplicate-chip edge — worth a fast-follow, not a block.
