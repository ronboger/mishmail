---
date: 2026-07-27 17:00
kind: review
reviewer: Fable (Claude Code subagent, not a /codex:* command)
target: branch fix/html-infinite-scroll vs main (HEAD b9e64fb)
verdict: ship-it
codex_session_id: n/a
job_id: review-20260727T170023-4314
duration: ~3m
invoked_from: /Users/ronboger/mishmail/.worktrees/html-infinite-scroll
git_branch: fix/html-infinite-scroll
git_head: b9e64fb496ebed6cf19a5faba9e99a8694275840
diff_size: 5 files, +542 / −33
focus: >
  Re-review after closing all findings from 2026-07-27-1650 review: two-hit
  freeze, recycle teardown, declaration-anchored vh CSS, JS/Swift mirror,
  image layout / height cache regressions.
prior_review: docs/codex-reviews/2026-07-27-1650-fable-review-html-infinite-scroll.md
---

# Fable Re-Review — `fix/html-infinite-scroll` vs `main`

**Mode:** READ-ONLY (no files modified) · **HEAD:** b9e64fb · **Diff:** 5 files, +542/−33

## Verdict: **SHIP-IT**
All 8 prior findings are closed or intentionally residual with sound rationale. No new blockers. Two cosmetic nuances and one standing test gap noted.

---

## 1. Findings by severity

### Status of prior findings 1–8

| # | Prior | Status | Evidence |
|---|---|---|---|
| 1 | HIGH | **Closed** | Bare `[height="100"]` dropped; percent-only rule `HTMLBodyLayout.swift:228-231`; absence guarded `HTMLBodyLayoutTests.swift:153-156`. |
| 2 | MED | **Closed** | Unfreeze gated on `img.complete && naturalWidth > 0` `:490-498`; `error` no longer clears freeze. |
| 3 | MED | **Closed** | Neutralization is **min-height only** (`killMin`, `setProperty('min-height','0')` `:427-433`); no sticky `height:auto` on coincidental heroes. |
| 4 | MED | **Closed** | RO walk early-returns on `__mmLastNeutralVH === vh` `:412-417`, skipping the O(n) `getComputedStyle` walk when viewport is unchanged. |
| 5 | LOW | **Residual (improved)** | Freeze now needs **2 consecutive** dH≈dVH samples (`feedbackHitsToFreeze=2`) before pinning — materially cuts single-sample clip risk. |
| 6 | LOW | **Closed** | Dead `cs.height !== 'auto'` guard removed with the height-kill path. |
| 7 | LOW | **Residual (mitigated)** | Selectors now **declaration-anchored**; bare `1100vh` no longer matches (verified: `height:100vh` is not a substring of `min-height:1100vh`). Guarded `:166-167`. |
| 8 | LOW | **Closed** | New `recycle()` helper `ThreadDetailView.swift:2438-2448` runs `teardownJS` on **every** path; all 7 sites funnel through it and it's the sole `HTMLWebViewPool.recycle` caller. |

### Re-review focus checks

- **Two-hit freeze correct & JS mirrors Swift.** JS `report()` (`:504-527`) matches `observeFeedback` (`:100-123`): first feedback sample sets `base=lastH`, `hits=1`, no freeze; second consecutive freezes at pre-streak `base`; a non-feedback sample resets. Unit-tested (`:101-129`, freeze at 500). Constants match Swift↔JS (`HITS_TO_FREEZE=2, MIN_DELTA=2, DELTA_TOL=4`, guarded). ✅
- **Teardown on every pool path.** Two independent layers: coordinator `recycle()` **and** `HTMLWebViewPool.clearForReuse` (`WebViewPool.swift:222`) — the latter covers `recycle`/`parkPrerender`-eviction/`discardAllPrerenders`/`drain`. Double teardown is idempotent (guarded IIFE). ✅
- **Anchored vh CSS** rejects bare `100`, bare `100vh`, and `1100vh`. ✅
- **No image-layout / height-cache regression.** `didReceiveHeight` swaps `max(raw,floor)` → `clampContentHeight` (`:2642`), preserving the floor and adding the 50k ceiling; `rawHeight>0` guard and `heightStability` flow unchanged; snapshot/restore/reflow untouched. ✅
- **Frozen path now clamped** — returns `postHeight(__mmFrozenH)`, and `postHeight` clamps to `[MIN_H, MAX_CONTENT_H]` (`:466-475`), closing the prior "un-clamped frozen post" note; Swift `clampContentHeight` is the hard backstop. ✅

### New observations (informational, not blockers)

- **VLOW** — `[style*="height:100vh"]` also matches `max-height:100vh`, applying `min-height:0; height:auto`. Harmless (`height:auto` is default; `min-height:0` benign on a max-capped box). `:218-219`.
- **VLOW** — `clearForReuse` already does `removeFromSuperview` + `teardownJS` unconditionally, so the coordinator's `removeFromHierarchy` flag and its own `teardownJS` are belt-and-suspenders. No behavioral difference; fine for locality.

## 2. Open questions

1. **Residual #5:** for a rare image-less marketing doc, a false-positive 2-sample freeze has no unfreeze trigger (only real image geometry or teardown clears it) and would clip below `frozenH` for the doc's life. Accepted trade-off vs. a periodic "still-feedback?" re-arm? (I'd accept — the 2-hit gate makes it very unlikely.)
2. **Coverage:** JS assertions remain `String.contains`; freeze math is exercised only via the Swift `observeFeedback` mirror, never a real DOM. Is a WKWebView `min-height:100vh` fixture planned, or explicitly out of scope?

## 3. Suggested fixes (NOT applied — review only)

None required to ship. Optional later: (a) anchor vh selectors to a `:`/`;`/start boundary to exclude `max-height`; (b) add one behavioral WKWebView test for a 100vh document to close the standing test gap.

---

I did not modify any files (Write was unavailable in this read-only context, and none was needed). This is a review deliverable, not an implementation plan — there are no code changes to approve.
