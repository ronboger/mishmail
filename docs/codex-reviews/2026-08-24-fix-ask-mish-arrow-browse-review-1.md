---
date: 2026-08-24 16:38
kind: fable-iterate review
review_model: claude-fable-5
review_effort: low
requested_model: claude-fable-5
resolved_model: claude-fable-5
model_substitution: none
job_id: review-20260824T163609-7359
branch: fix/ask-mish-arrow-browse
base: main (11eb998)
reviewed_commit: b112258f8eb26efb331284d2cddc33a2029efcc6
verdict: SHIP
started_at: 2026-08-24T23:36:09Z
finished_at: 2026-08-24T23:38:35Z
checks: make test → TEST SUCCEEDED, 1711 tests, 5 skipped, 0 failures
total_cost_usd: 2.243982
num_turns: 16
duration_ms: 142711
---

# Review pass 1 — Ask Mish ↓ must not open the next email

## Prompt

```
Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: When Ask Mish is open, Down must not open the next email. The user wants to keep scrolling the Ask Mish chat (or the thread list) instead. Enter still opens a thread. j/k may still move the highlight but must not hydrate the reading pane while Ask Mish is visible.
```

## Verbatim review

## Review: fix/ask-mish-arrow-browse (b112258) vs main

The change is correct and complete for the task. All 52 affected tests pass (`ReadingPaneSpaceScrollTests`, `SelectionAdvanceTests`, 0 failures).

### How the fix works
Two independent gates cover the two input paths:

1. **↓/↑ arrows** — the key monitor (`ContentView.swift:1350`, `:1361`) checks `askMishVisible(in:)` live from the event window. If Ask Mish is on screen and a pane can scroll, the key scrolls it and is swallowed. If nothing can scroll, it falls through to `moveSelection(intent: .browse)`.
2. **j/k** — `KeyBindings` routes to `MailStore.performCommand` → `moveSelection` with the default `.browse` intent. The selection `onChange` in `ContentView.swift:216` now calls `DetailOpenPolicy.browseOpensDetail` (`SelectionAdvance.swift:225`), which blocks hydration when `askMishPanelWidth > 0`. The highlight still moves; the pane does not open. Enter and click use different intents and stay unaffected.

I verified that the two visibility checks agree: the `GeometryReader` sits at the window root, so `proxy.size.width` and `window.contentView.bounds.width` match. Both feed `AskMishLayout.showsPanel`. The scroll target lookup (`readingPaneScrollView`, `ContentView.swift:1510`) correctly finds the Ask Mish chat: it is a SwiftUI `ScrollView` (`AskMishPanelView.swift:236`), not an excluded `NSTableView`/`NSTextView`, and it is the rightmost candidate. Text-field focus is safe: the monitor's guard at `ContentView.swift:1295` passes arrow keys to an editable field, so the caret still moves in the chat composer.

### Findings

**Low — one-frame staleness between the two gates.** The key monitor computes visibility live; the `onChange` gate reads `askMishPanelWidth`, which updates through `.onChange(of: panelWidth)` (`ContentView.swift:170`). During a window resize across the 900px threshold, the two can disagree for one frame. The worst case is one extra highlight-only move. Not worth fixing.

**Low — behavior note, matches the changelog.** When the chat cannot scroll (short chat, or at the bottom), ↓ scrolls the conversation beside it; when neither can scroll, ↓ moves the list highlight. So a held ↓ transitions chat → conversation → highlight. The CHANGELOG documents this exact behavior, so I treat it as intended.

**Nit — small duplication.** The `page ? pageTarget : lineTarget` ternary in `scrollPane` (`ContentView.swift:1482-1494`) passes identical arguments twice. It could call `offsetTarget` with one computed step. Cosmetic only.

**Test coverage.** The pure helpers have direct tests, including the new `step <= 0` guard. The AppKit wiring (key monitor, scroll-view walk) has no tests, which matches the existing pattern in this codebase. No gap I would block on.

### Open questions
None. The compact-width case is covered: `showsPanel` is false below 900px, so Ask Mish never renders there and the gate is moot.

### Verdict
**SHIP.**
