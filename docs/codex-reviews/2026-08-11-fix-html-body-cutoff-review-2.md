---
date: 2026-08-11 10:55
kind: fable-iterate re-review
review_model: claude-fable-5
review_effort: low
job_id: review-20260811T105544-61203
branch: fix/html-body-cutoff-20260811-104905
base: main (5a11a7d)
reviewed_commit: db93649
verdict: SHIP
checks: HTMLBodyLayoutTests → 30 tests, 0 failures; full suite earlier 1432/0
---

# Review pass 2 — after Medium findings

Permission deny rule "MultiEdit" matches no known tool — check for typos.
Ran the full `HTMLBodyLayoutTests` suite on this branch: 30 tests, 0 failures.

## Findings

**Medium — fixture may not exercise the clipsContent path it documents**
`Tests/MishMailTests/Fixtures/Transactional2FA.swift:137` — the clipping shell is a `<table class="shell">` with stylesheet `height: 100%; overflow: hidden`. In standards mode (the fixture has a doctype), CSS `height` on a table acts as a *minimum*: content taller than 100% expands the table, and `overflow: hidden` doesn't stop that. So the shell likely never clips — `scrollHeight ≈ border box`, `clipsContent` never fires, and plain border-box measure already succeeds. The structural test (`HTMLBodyLayoutTests.swift:500`) is string-containment only, so nothing catches this. If the real Fidelity mail uses a `div` shell, the code path is right but the fixture doesn't reproduce the bug; a `div`-based shell (or an integration test in a real WKWebView) would.

**Low — "never kill plain-px heights" only holds for inline px**
`HTMLBodyLayout.swift:584-589` — `styleLooksPx` reads `el.style.height`, so it exempts only *inline* px. A stylesheet-authored fixed-px hero (`.hero { height: 700px; overflow: hidden }`) whose computed height happens to equal the viewport, with content overflowing by >8px, still gets `height: auto`'d. The overflow requirement makes collateral damage unlikely (revealing clipped content is usually the right call), but the comment overstates the guarantee.

**Low — `overflowClips` includes `scroll`/`auto`**
`HTMLBodyLayout.swift:583` — `scroll`/`auto` produce inner scroll regions, not clipping. Collapsing them is probably desirable in a reading pane (no nested scrollbars), but it's broader than the "clips overflow" comment and the pass-1 remit ("requires overflow clip").

**Low — full neutralize walk on every image event**
`HTMLBodyLayout.swift:751-752` — `onImgEvent` resets `__mmLastNeutralVH` and re-walks `body, body *` with `getComputedStyle` per image load/error. An email with hundreds of blocked images does hundreds of O(n) walks. Each image fires once, so it's bounded — noting for awareness only.

**Low — near-zero-height preheaders can add phantom height**
`HTMLBodyLayout.swift:613-621` — the `r.height <= 0` guard covers `max-height:0`/`display:none`, but a `height:1px; overflow:hidden` preheader (a real pattern) passes it, and its scrollHeight then extends `edge`. Only matters if the preheader's scroll extent exceeds every other child's bottom — rare, and bounded by `MAX_CONTENT_H`.

## Pass-1 items — verified addressed

- scrollHeight only on real overflow: `sh > r.height + 8` at line 620 ✓
- skip `r.height <= 0` kids: line 613 ✓
- clipsContent requires overflow clipping and excludes plain-px: lines 583-589 ✓ (with the inline-only caveat above)

## Open questions

- Does the actual Fidelity email use a `div` or `table` shell? Determines whether the fixture reproduces the original bug (Medium finding).
- Was the fix verified visually against the real message? The unit tests are string-containment on generated JS, not behavior.

## Suggested fixes (not applied)

1. Change the fixture shell from `<table>` to `<div>` (or add a div variant) so it genuinely clips, and ideally add a WKWebView-based measure test.
2. Soften the comment at line 577-580 to say inline px only, or also check `attrH` px.

**SHIP** — the code changes are correct and conservative; the Medium finding is a test-fidelity gap, not a product bug.
