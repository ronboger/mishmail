---
date: 2026-08-11 10:52
kind: fable-iterate review
review_model: claude-fable-5
review_effort: low
job_id: review-20260811T105200-59034
branch: fix/html-body-cutoff-20260811-104905
base: main (5a11a7d)
reviewed_commit: e976ddf
verdict: SHIP
checks: make test → TEST SUCCEEDED, 1432 tests, 5 skipped, 0 failures
---

# Review pass 1 — clipped HTML body measurement

Permission deny rule "MultiEdit" matches no known tool — check for typos.
## Review: `e976ddf` vs main — clipped HTML body measurement

### Findings by severity

**Medium — per-child `scrollHeight` can re-couple measure to the viewport for non-clipping `height:100%` wrappers.**
`Sources/MishMail/Support/HTMLBodyLayout.swift:608-610`: `edge = Math.max(r.bottom, r.top + sh)`. Per spec, `scrollHeight` floors at `clientHeight`. For a body child with stylesheet `height:100%` whose content is *short* (so `clipsContent` is false and nothing neutralizes it), `sh == clientHeight ≈ vh`. If that wrapper sits below any spacer (`r.top > bodyTop`), measured content = offset + vh — strictly greater than the viewport every cycle, i.e. the same re-latch mechanism the diff's own doc comment says it avoids for `documentElement.scrollHeight`, reintroduced per-child. The feedback guard (`isFeedbackGrowth`, line 693) will freeze the growth, and recovery is capped by `RECOVERY_MAX_ADOPTIONS`, so it's bounded — but it burns the adoption budget and can land the card oversized by `offset × adoptions`. The fixture doesn't cover this shape (its shell starts at bodyTop).

**Medium — hidden-trail dead gap can return for `max-height:0; overflow:hidden` containers.**
`HTMLBodyLayout.swift:601-606`: the skip only covers `r.height <= 0 && sh <= 0`, i.e. `display:none`. An element collapsed with `max-height:0; overflow:hidden` (a real pattern for preheaders and some quote/footer hiding) has border-box 0 but full `scrollHeight`, so `r.top + sh` extends `bottom` past the visible content — the dead-gap regression the old border-box-only code was written to prevent. Most preheaders also set `display:none`, so exposure is limited, but a bottom-of-body hidden block would reopen the gap.

**Low — fixed-px heroes are no longer unconditionally protected.**
Old code neutralized only percentage-authored heights; new `killHeight = nearVH && (authoredPct || authoredVh || clipsContent)` (line 582) will set `height:auto !important` on a fixed `height:600px` hero that clips overflow (e.g. cropped background image) whenever the viewport happens to be within 2px of 600. That visibly changes rendering of a legitimate design. Rare coincidence, but it's exactly the case the deleted comment guarded.

**Low — `authoredVh` regex misses forms.**
Line 572: `/\d+(\.\d+)?(vh|dvh|svh|lvh)$/` doesn't match `calc(100vh)`, `.5vh`, or `min(100vh, …)`. Stylesheet `vh` is only caught indirectly via `clipsContent`. Fine as a heuristic; noting for completeness.

**Test coverage — string-contains only; behavior unverified.**
`HTMLBodyLayoutTests.swift:447-505` asserts substrings of the generated JS, and `testClippedViewportWrapperFixtureHasTallBodyAndShell` asserts substrings of the fixture HTML. Nothing executes `clippedViewportWrapperHTML` through the measure JS (no WKWebView test), so the actual fix — "this fixture now measures tall" — is not tested. This matches the repo's existing test style, but it means both Medium findings above have no regression net. I did not run the test suite (read-only session, and tests are string checks anyway).

### Open questions
1. Was the fix verified against the real Fidelity confirmation email in the app? The commit message implies so but nothing in-repo records it.
2. Is there any in-app quote collapsing that uses `max-height:0`/`height:0` rather than `display:none`? I found none in `Sources/` (only emails' own inline `display:none`), which is why finding 2 is Medium not High.

### Suggested fixes (not applied)
- Finding 1: only use `r.top + sh` when the element actually clips (`sh > r.height + 8` **and** computed `overflow-y` is not `visible`), or subtract the `clientHeight` floor when computed height is percentage/viewport-tied.
- Finding 2: same guard fixes this — additionally skip when `r.height <= 0` and computed `max-height` is `0px`.
- Finding 3: require computed `overflow-y` ∈ {hidden, clip} plus non-px authored height before `clipsContent` can kill a height, or keep the fixed-px exemption and rely on the measure-side scrollHeight instead (neutralization may be unnecessary for the clip case now that measure sees the overflow).

### Verdict
**SHIP** — the core fix is sound and the dangerous global (`documentElement.scrollHeight`) stays excluded; both residual risks are bounded by the existing freeze/adoption guards. The `max-height:0` dead-gap case and the viewport re-latch offset case are the two things to watch, and a WKWebView-based test executing the new fixture would close the real gap.
