---
date: 2026-08-03 17:50
kind: fable-iterate review (planner/reviewer: Claude Fable 5; implementer: Grok 4.5)
implementer_model: grok-4.5
grok_jobs:
  - ship-20260803T173512-52611 (initial implementation)
  - rescue-20260803T174536-59132 (pass-2 fix for review finding)
branch: jacq/ship-20260803T173512-52611
base: main (39afdcf)
reviewed_commits:
  - 72a919c fix: recover false height freezes and neutralize percentage wrappers
  - b189b75 fix: anchor freeze guard to streak-start viewport
verdict: SHIP
checks: make test → TEST SUCCEEDED, 1291 tests, 5 skipped, 0 failures; make build → 0 warnings
---

# Review — compressed HTML email body (reading pane height collapse)

## Symptom

A transactional 2FA email rendered as a ~120px card: an empty box, a horizontal
rule, and a half-clipped "Hello Ron". Real authored content below was
unreachable — the card was not scrollable, it was sized wrong.

## Diagnosis

`HTMLBodyLayout` sizes each reading-pane `WKWebView` to the measured content
height, so the outer SwiftUI `ScrollView` owns scrolling. That creates a
measure → grow frame → viewport grows → measure grows feedback risk for email
templates whose wrappers are sized against the viewport. The file defends with
anti-feedback CSS, JS neutralization of viewport-tied min-heights, and a freeze
state machine that pins the published height after two consecutive dH≈dVH
samples.

Three facts combined into the bug:

1. Neutralization covered `height="100%"` attributes and `100vh/dvh/svh/lvh`
   inline declarations, plus computed *min-height* ≈ viewport. It did **not**
   cover percentage CSS heights (`height: 100%` inline or from a stylesheet),
   so those wrappers still coupled content height to viewport height.
2. That coupling produced dH≈dVH samples during the early load, while the host
   frame was still small, and the freeze fired at the tiny pre-streak height.
3. The only unfreeze path was an image loading successfully with
   `naturalWidth > 0`. MishMail blocks remote images by default, so every image
   errored and the freeze was permanent. The card stayed compressed forever.

## Changes reviewed

1. **Percentage-height neutralization** (root cause). `antiFeedbackCSS` gains
   declaration-anchored `[style*="height:100%"]` / `[style*="min-height:100%"]`
   selectors; `neutralizeViewportHeights()` also sets `height: auto !important`
   when the authored height is percentage-based (inline `%` or `%` attribute)
   *and* the computed height is within 2px of the viewport. Fixed-px heroes and
   replaced elements (img/svg/video/canvas) are untouched, and bare
   `height="100"` (100px spacers in transactional mail) still does not match.
2. **False-freeze recovery**. While frozen, the JS keeps measuring. New pure
   `observeFreezeRecovery` (mirrored in JS) adopts a taller measured height when
   the viewport has been unchanged for 2 consecutive samples and the measurement
   exceeds the frozen height by more than 8px, with a budget of 3 adoptions per
   document. This removes the dependency on image loads for unfreezing. Under a
   genuine loop the pinned frame makes measurement settle at ≈ the frozen value,
   so no adoption occurs; growth stays bounded by the budget and
   `maxContentHeight`.
3. **Below-viewport freeze guard**. `observeFeedback` refuses to freeze when the
   streak base height is below the streak-start viewport, without clearing the
   streak.

## Finding raised in pass 1 (fixed in pass 2)

**Guard drift defeated the anti-runaway freeze entirely.** As first written, the
guard compared the pinned streak `base` against the *live* `viewport`:

    if base + feedbackDeltaTolerance >= viewport { freeze = base }

`base` is fixed for the life of the streak while `viewport` grows every sample of
a runaway, so once the gap passed the 4px tolerance the guard blocked the freeze
permanently. Trace with content = viewport + 20 and the frame tracking the
published height:

| sample | prev (h, vh) | (h, vh) | old behavior |
|---|---|---|---|
| 1 | (100, 80) | (120, 100) | feedback, hits 1, base 100 |
| 2 | (120, 100) | (140, 120) | 100+4 >= 120 false → refused (previously froze at 100) |
| 3+ | … | … | vh drifts further → refused forever |

The result was unbounded growth to the 50k `maxContentHeight` clamp — the exact
infinite-scroll behavior the freeze exists to prevent. Grok's own test comment
documented the drift rather than catching it.

**Fix (commit b189b75):** the guard is anchored to the viewport captured at the
*start* of the streak (`FeedbackStep.streakBaseViewport` in Swift,
`window.__mmFeedbackBaseVH` in the JS mirror, reset on every existing reset
path), so it cannot drift. A regression test walks the trace above and asserts
the freeze fires at hit 2 at the pre-streak base.

## Verification

- `make test` in the worktree: **TEST SUCCEEDED**, 1291 tests, 5 skipped,
  0 failures (the whole suite, not just the HTMLBody filter).
- `make build`: 0 warnings.
- Both Grok passes reported VERIFICATION-BLOCKED (its sandbox cannot resolve SPM
  packages) and committed with `--no-verify`; all verification above was run by
  the reviewer outside the sandbox.

## Residual risk (accepted)

- Freeze recovery permits at most 3 bounded height adoptions per document before
  the freeze becomes permanent again; worst case is a few growth steps rather
  than a pin, always under `maxContentHeight`.
- A streak that begins while the frame is still catching up (base < streak-start
  viewport) cannot freeze until a non-feedback sample resets the streak. Real
  loops keep viewport ≈ content, so this state ends on its own, and the
  `maxContentHeight` clamp bounds it regardless.

**Verdict: SHIP.**
