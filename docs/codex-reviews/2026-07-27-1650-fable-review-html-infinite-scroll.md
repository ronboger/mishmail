---
date: 2026-07-27 16:50
kind: review
reviewer: Fable (Claude Code subagent, not a /codex:* command)
target: commit 161bae8 "Stop infinite HTML body height growth from marketing templates"
verdict: needs-attention → addressed in ee126b1 (findings 1, 2, 3 partial, 4)
codex_session_id: n/a
job_id: review-20260727T165029-1161
duration: ~4m
invoked_from: /Users/ronboger/mishmail/.worktrees/html-infinite-scroll
git_branch: fix/html-infinite-scroll
git_head: 161bae8576719efb4856bab3d71bf892c052fb97
diff_size: 4 files, +192 / −3
focus: >
  anti-feedback correctness (CSS + neutralizeViewportHeights + freeze dH≈dVH);
  maxContentHeight 50k clamp; legitimate tall layouts / image placeholders;
  ResizeObserver re-entry; recycled WebView teardown; security of body * walk;
  test coverage gaps.
follow_up_commit: ee126b1edf98d7c7d334e6e13a586b43013271fc
---

# Code Review — `fix/html-infinite-scroll` (161bae8)

**Scope:** anti-feedback CSS/JS, `maxContentHeight` clamp, neutralization heuristic, ResizeObserver re-entry, recycled-view teardown, security of styling untrusted HTML, test coverage. Reviewed against `main`.

Overall the design is sound: neutralize known vh-tied heights up front, clamp reported height on both JS and Swift sides, and freeze reports that track frame growth. The clamp mirroring is clean and well-tested. Below are the issues, ordered by severity.

## Findings

### 1. HIGH — `[height="100"]` CSS rule collapses legitimate fixed-pixel spacers
`Sources/MishMail/Support/HTMLBodyLayout.swift:150-155`

```css
table[height="100"], tbody[height="100"], tr[height="100"],
td[height="100"], th[height="100"], div[height="100"] {
  height: auto !important;
}
```

The comment targets *"Full-bleed `height="100%"` tables"*, but the bare `="100"` variants match `height="100"` — which in HTML means **100 pixels**, not 100%. `<td height="100">` / `<div height="100">` fixed-height spacer cells are ubiquitous in exactly the transactional templates this file's doc-comment says it exists to protect (2FA/receipt spacers, `HTMLBodyLayout.swift:7-12`). Forcing them to `height: auto !important` collapses intended vertical whitespace (empty spacer cells drop to ~0/line-height).

A bare `height="100"` element is a *fixed* box — it can't track the viewport — so it provides **zero** anti-feedback benefit and only introduces false positives. Only the `="100%"` selectors are load-bearing here.

Evidence it's untested: `testAntiFeedbackCSSNeutralizesFullBleedHeights` (`Tests/…/HTMLBodyLayoutTests.swift:88-94`) asserts only `height="100%"` — the bare-100 rule has no coverage and no guard.

**Suggested fix:** drop the `[height="100"]` selector group entirely; keep only `[height="100%"]`.

### 2. MEDIUM — Freeze is cleared on every image load/error, enabling oscillation
`HTMLBodyLayout.swift:414-419`

```js
function onImgEvent(ev){
  applyImage(ev.target);
  window.__mmFrozenH = 0;   // clears freeze on ANY image load OR error
  report();
}
```

Under the Ask/blocked-image policy, images fire `load`/`error` at staggered times (and `error` fires for every blocked remote image). Each event unfreezes, so a template still in the measure→frame loop resumes growing until the delta-heuristic re-freezes. With several images/tracking pixels resolving over time this can produce visible height oscillation (grow → freeze → image event → grow → freeze…), and each publish re-runs through `HTMLHeightStability`, which never reaches `isStable` (`HTMLBodyPerformance.swift:325-334`) so `finishRender(reason: "stable")` may not fire.

The unfreeze is intentional (real image geometry should be allowed), but clearing on *all* images unconditionally is too broad — an `error` on a blocked image changes nothing geometrically once its placeholder is already applied.

**Suggested fix:** only clear the freeze when the image actually gained real geometry (`img.complete && img.naturalWidth > 0`), not on `error`; or re-arm the freeze immediately if the post-event report still tracks the frame.

### 3. MEDIUM — `neutralizeViewportHeights` can permanently collapse a coincidentally viewport-sized element
`HTMLBodyLayout.swift:329-354`

The kill condition is `>= 200 && Math.abs(x - vh) <= 2`. Any legitimately fixed-size block (e.g. a hero/spacer `height: 600px`) that momentarily equals the current viewport (e.g. when the card is restored from a cached ~600px height) matches, gets `height: auto !important` **and** the sticky `NEUTRAL` class — which excludes it from all future re-checks (`:336`). So a one-frame coincidence collapses the element for the life of the document even after the viewport moves away. The ±2px window makes this rare, but it's a real false-positive with no recovery path.

**Suggested fix:** require corroboration before killing (e.g. the element's height changed *in lockstep* with a viewport change across two samples), rather than a single-instant equality; or don't make the neutralization sticky for `height` (only for `min-height`, which is the actual vh vector).

### 4. MEDIUM — O(n) full-DOM style walks on every ResizeObserver callback (CPU/DoS on large untrusted DOMs)
`HTMLBodyLayout.swift:441-448`, `:329-354`

Each ResizeObserver tick runs `neutralizeViewportHeights` (`querySelectorAll('body, body *')` + `getComputedStyle` per node — forces full style recalc) **plus** `reflowPlaceholders` (full `img` walk) **plus** `measure` (per-child `getBoundingClientRect` — forces layout). All three mutate style inside the observer callback, which itself schedules further resize notifications. For a large adversarial/marketing DOM this is O(nodes) per resize and can pin CPU. Email HTML is explicitly untrusted (`:23-28`); the 50k px height clamp bounds the *frame* but nothing here bounds *node count*. `reflowPlaceholders`/`measure` were pre-existing, but adding a second full-tree `getComputedStyle` walk on the hot path meaningfully raises the cost.

**Suggested fix:** gate `neutralizeViewportHeights` in the RO callback so it only runs when the viewport height actually changed since the last neutralize (cache last `vh`); the `NEUTRAL` class already prevents re-mutation but not the re-scan.

### 5. LOW — Freeze delta heuristic can false-trigger on genuine simultaneous growth; frozen content is clipped
`HTMLBodyLayout.swift:394-401`, `:381-389`

`if (dH > 2 && dVH > 2 && Math.abs(dH - dVH) <= 4)` freezes at `lastH`. Because the WKWebView fills the container and scrolling is owned by the outer pane, a premature freeze pins the frame *shorter* than real content, which WKWebView then clips (content below `frozenH` becomes unreachable). The main protection is that `neutralize` normally runs first, but this backstop trusts a single-sample delta match. Consider noting the assumption that `neutralize` has already fired; otherwise a legitimately-growing document (late web-font swap while the frame is still catching up from a prior publish) could hit the `dH≈dVH` window and clip.

### 6. LOW — Dead guard `cs.height !== 'auto'`
`HTMLBodyLayout.swift:345-346`

`getComputedStyle().height` resolves to a px string, never the literal `'auto'`, and `parseFloat('auto')` is `NaN` (already rejected by `ht === ht`). The `&& cs.height !== 'auto'` clause is always true — harmless, but misleading. Not a bug.

### 7. LOW — Substring attribute selector over-matches
`HTMLBodyLayout.swift:157-161`

`[style*="100vh" i]` matches any inline style *containing* `100vh` as a substring — e.g. `1100vh`, `2100vh`, or `100vh` on an unrelated property. Practically harmless (setting `height:auto/min-height:0` on such elements is benign), but worth a note; it's not anchored to a `height`/`min-height` declaration.

### 8. LOW — `teardownJS` not run on the `incoming`/`previous` recycled views
`Sources/MishMail/UI/ThreadDetailView.swift:2580-2584`, `:2678-2683`

`dismantle()` evaluates `teardownJS` only on `current`; the `incoming` branch and `revealIncoming`'s `previous` recycle path skip it (they only `removeHeightHandlerIfNeeded()`). In practice this is safe — `__mmFrozenH`/`__mmLastH` are per-document globals reset by `installLayoutAndMeasureJS:421-424`, and a recycled view reloads a fresh document that discards the old JS context — so the freeze cannot leak across documents. The teardown reset is belt-and-suspenders; just flagging the asymmetry in case reuse-without-reload paths are added later.

## Security assessment
No injection surface: the JS only calls `el.style.setProperty(...)` and `classList.add(...)` on nodes it reads; it never writes `innerHTML` or evaluates attribute values as code. Attribute/`[style*=]` selectors are static. The real security-relevant concern is **CPU DoS via O(n) hot-path walks on untrusted DOMs** (Finding 4), and the height clamp (JS `measure:371` + Swift `clampContentHeight`) correctly bounds the published frame. The frozen-report path posts `__mmFrozenH` un-clamped (`:382-388`), but that value derives from an already-clamped `measure()`, and Swift `clampContentHeight` (`ThreadDetailView.swift:2638`) is a hard backstop — so the ceiling holds.

## Test coverage gaps
- **No behavioral test of the JS at all** — every assertion is `String.contains` on the generated CSS/JS (`HTMLBodyLayoutTests.swift:88-149`). The core logic (freeze delta math, `neutralizeViewportHeights` threshold, img/svg skip) is unverified. A `JSContext`/DOM-shim or a WKWebView integration fixture with a `min-height:100vh` document asserting bounded height would actually exercise the fix.
- **No regression test** distinguishing `height="100%"` from `height="100"` (Finding 1) — the current test would still pass after removing the buggy rule, and would also pass with the bug present.
- **No test** that `maxContentHeight` clamps the *frozen* path, or that freeze survives/should-not-survive image events (Finding 2).
- `clampContentHeight` itself is well covered (floor, cap, `.infinity`, `.nan`) — `HTMLBodyLayoutTests.swift:66-79`. Good.

## Open questions
1. **Finding 1:** Is the `[height="100"]` (no `%`) selector intentional? If some observed template really writes `height="100"` meaning full-bleed, that's non-standard — do you have a concrete sample, or was it added by analogy to the `%` rule?
2. **Finding 2:** Should a blocked-image `error` really clear the freeze? Nothing about the layout changes once the placeholder is applied.
3. **Finding 3:** Is permanent (sticky-class) neutralization of `height` (as opposed to `min-height`) desired, given a fixed-px element can match the viewport only transiently?
4. Do you have a repro fixture (the Thumbtack email) checked in anywhere for manual/automated verification? It isn't in this diff.

I have **not** modified any files. Let me know if you'd like suggested patches for any of these (Findings 1 and 2 are the highest-value, lowest-risk fixes).

---

## Follow-up (ee126b1)

Addressed pre-merge items from this review:

| # | Fix |
|---|-----|
| 1 | Dropped bare `[height="100"]` selectors; percent-only full-bleed rule; test asserts bare-100 is absent |
| 2 | Unfreeze only when `img.complete && naturalWidth > 0` (not on blocked-image error) |
| 3 | Neutralize only `min-height≈viewport` (no sticky `height:auto` on coincidental fixed heroes) |
| 4 | Gate neutralize on `__mmLastNeutralVH` so RO ticks with unchanged viewport skip the O(n) walk |
| 6 | Dead `cs.height !== 'auto'` guard removed with the height-kill path |

Left as residual (LOW / deferred): freeze false-trigger clipping (#5), substring `100vh` selector (#7), teardown asymmetry (#8), behavioral WKWebView fixture for 100vh documents.
