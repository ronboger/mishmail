---
date: 2026-07-28 12:43
kind: fable-review
target: feat/greeting-tab-autocomplete vs main
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260728T124312-48693
reviewed_commit: 2cdf297623ba9e393d927a50cc43732824bd82e2
invoked_from: /Users/ronboger/mishmail/.worktrees/greeting-tab-autocomplete
git_branch: feat/greeting-tab-autocomplete
---

# Review prompt

Re-review the complete diff against the requested task after fixing the Medium finding (caret-past-head clamp). Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: Gmail-style tab autocomplete for the beginning of threads — Hi/Hey {first name} with greyed-out ghost text visual cue, Tab to accept.

# Re-Review: Greeting Tab Autocomplete (feat/greeting-tab-autocomplete vs main)

**Scope note:** the branch is 2 commits behind main (`9231f73`, `6d69bd3` — the slash-picker layout fix). The apparent deletions of `SlashSnippetPickerLayout.swift`, its tests, and the `layoutPriority`/floor-cap logic in a plain `git diff main` are **merge-base artifacts, not changes on this branch** (`git log main..HEAD -- <those files>` is empty). The real diff (merge-base `39dec3a..HEAD`) is +382/−1 across 5 files.

## Medium finding (previous review) — verified fixed

The caret-past-head clamp is gone and replaced with strict gating at both layers:

- `GreetingAutocomplete.swift:56` — `guard caretUTF16 == ns.length else { return nil }`, explicitly documented as "do not clamp".
- `ComposeView.swift:1489` (`greetingSuggestion`) — `guard bodyCaretUTF16 >= 0, bodyCaretUTF16 <= headUTF16 else { return nil }`, mirroring the identical guard in `slashToken` (ComposeView.swift:1449).
- Regression tests cover it directly: `GreetingAutocompleteTests.swift:92-102` (`testCaretPastHeadDoesNotClampIntoGreeting`, including negative caret) and `:85-90` (caret mid-head).

`applying()` still clamps (`GreetingAutocomplete.swift:82`), which is correct there — it's a defensive bound on the head-end offset for the replace, not a suggestion gate, and it's only reachable after `greetingSuggestion` already validated the caret.

## Findings

**Low 1 — Guessed names from bare addresses can produce awkward greetings.**
`greetingRecipientFirstName` (ComposeView.swift:1455-1467) falls through to `person(from:)` (ComposeView.swift:1750), which fabricates a name from the local part: `info@acme.com` → ghost "Hi Info, ", `ronboger@gmail.com` → "Hi Ronboger, ". Gmail only offers greetings for known display names. Product-quality nit, not a bug; the mined-contact override mitigates it for known senders.

**Low 2 — Unicode-case edge in ghost slicing.**
`suggestion()` compares `lowercased()` strings but slices the ghost by the *original* typed UTF-16 length (`GreetingAutocomplete.swift:70-76`). For names/typing where lowercasing changes UTF-16 length (Turkish `İ` → `i̇`, `ß`), the ghost could be off by a unit. Self-correcting on Tab (Tab replaces the whole head with canonical `full`), so purely a transient display glitch. Not worth fixing unless it shows up.

**Low 3 — `firstName(of:)` splits only on literal spaces.**
`GreetingAutocomplete.swift:25-27` uses `split(separator: " ")` — a display name with a tab or non-breaking space between words yields the whole string as the "first name". Trivial hardening: split on `.whitespaces`.

**Low 4 — Ghost may draw during IME composition.**
`drawGhostText` (ComposeBodyEditor.swift:445-448) gates only on `sel.length == 0`; marked text (Japanese/Chinese composition) keeps a zero-length selection, so the grey suffix can render mid-composition. A `guard !hasMarkedText()` would clean this up. Cosmetic.

**Info — Rebase will conflict.**
Main's `6d69bd3`/`9231f73` touched the exact ComposeView regions (`bodyEditorMaxHeight`, `bodyEditorMinHeight`, picker `layoutPriority`, quote `Spacer`) and ComposeAccessories that sit adjacent to this branch's edits. Expect (small) conflicts on rebase/merge; the greeting logic itself is orthogonal to the layout fix, so resolution should be mechanical — but verify `SlashSnippetPickerLayout` survives.

## What's correct

- Two-layer caret gating (view guard `<= headUTF16`, pure gate `== length`) matches the established `slashToken` pattern and is well-commented against re-introducing the clamp.
- Tab routing (ComposeView.swift:1557-1561) correctly yields to the slash picker (`!slashActive` first), requires no modifiers, and `greetingSuggestion`'s `bodyFocused` guard keeps Tab-in-Subject unaffected.
- `applying()` preserves the quoted tail and parks the caret at the end of the accepted greeting; `setBody` (ComposeView.swift:247) clamps defensively.
- Ghost is draw-only, never enters the model string or the SwiftUI binding; hidden while `slashActive` or unfocused.
- Multiline-head and complete-greeting suppression both gated and tested.

## Test coverage

Strong for the pure layer: 16 tests covering empty body, all three openers, ambiguity preference (Hi > Hey > Hello), case-insensitivity, complete-greeting suppression, caret gating (mid-head, past-head, negative), multiline, non-matching prefix, and both `applying` paths. Gaps are all AppKit-side and inherently hard to unit test here: ghost drawing geometry, the NSEvent Tab monitor, and `greetingRecipientFirstName` (untestable as a private computed var — extracting the token→first-name resolution into the pure enum would make Low 1's behavior testable).

## Open questions

1. Is "Hi Info, " / "Hi Ronboger, " from bare addresses acceptable, or should the ghost require a real (contact/display) name? (Low 1)
2. Should acceptance land on top of current main before merge, given the guaranteed conflict region? (Info)

## Verdict

**SHIP** — the Medium finding is properly fixed with regression tests; remaining items are low-severity polish and a routine rebase.
