# Plan: Compose card clips / shifts on narrow windows

**Branch:** `fix/compose-narrow-clip`  
**Base:** `main` @ 2f770c4  
**Related:** `c69d625` (body sideways jump on Enter), `f1a9c0e` (inline layout livelock),
`60c81db` (side-by-side compose), `ComposePlacement.swift` / `composeChrome`

## Problem

On a **smaller window**, opening **reply compose** shifts the compose UI and
clips content so the draft is unusable. Screenshot (2026-07-29):

- Inline (or docked) reply open under the Aidan Pratt thread.
- Card header / body / From / To / Subject all lose their left edge mid-glyph:
  - context line shows `ying to Aidan Pratt` (should be `Replying to …`)
  - From shows `on@ronboger.com` (label + start of address gone)
  - Subject shows `fellow, opening a round` (lost `Re: KP `)
  - body starts mid-phrase
- Thread list dates sit immediately left of the cut.
- Footer right side (`Send`, `Draft saved`) still visible.
- Header title reads like the tail of `Draft: Re: KP fellow…` (draft autosave
  is active — status says “Draft saved”), consistent with a **uniform ~40–50pt
  left cut** across the whole card, not an NSTextView-only reflow.

User description: “shifts everything right and then I can’t see the whole thing.”

This is **not** the already-fixed Enter-key body jump (`c69d625` /
`pinHorizontalScroll` / overlay scrollers). That only affects the body
NSTextView. Here every SwiftUI row is cut the same way.

## What the inspection found

### Placement model (current)

`ContentView.composeChrome` hosts one `ComposeView` in a window-level
`.overlay(alignment: .bottomTrailing)`:

| Presentation | Width | Horizontal position |
| --- | --- | --- |
| **floating** | hard-coded **620** | trailing + 16pt pad (no leading spacer) |
| **inline** | `inlineMetrics.width` or fallback **620** | fixed leading spacer = `pane.minX − host.minX + 12` (or layout-mode fallback), flexible trailing spacer |
| **split** | `splitComposeWidth(host) − 2×12` | right column reserved in `splitComposeLayout`; chrome uses split pad |

Pure math lives in `ComposePlacement` (`inlineMetrics`, `fallbackLeadingInset`,
`splitComposeWidth`, `resolvedPresentation`). Tests cover happy-path metrics
and split clamps, **not** “card always fully visible on narrow hosts.”

### Ranked root-cause hypotheses

1. **HIGH — Card wider than available column / host, left edge under list or
   clipped by overlay parent.**
   - Floating always uses **620**. App `minWidth` is 900, but three-pane +
     list + sidebar leaves a much narrower trailing column; a 620 floating
     card (forward / off-thread / demoted) overflows left under the list.
   - Inline fallback width is also **620** when `inlineMetrics` is nil
     (zero frames on first layout, or pathological zero pane).
   - `inlineMetrics` does `width = max(minWidth: 280, pane.width − 24)`. The
     floor can **exceed** `pane.width − 24` on a short pane, so the card is
     wider than the pane by design.
   - Overlay children are clipped to the host. Depending on how the HStack
     is proposed (full width vs ideal width) and whether leading is overstated
     or understated, either the left of the card sits under the opaque list
     or the right is cut. Screenshot is consistent with **left of card
     covered/clipped ~40–50pt**.

2. **MEDIUM — Leading inset wrong (stale / mismatched global frames or
   fallback).**
   - `inlineMetrics` depends on `ComposeHostFrameKey` + `ReadingPaneFrameKey`
     both in `.global`. Any host/pane coordinate mismatch (titlebar, toolbar,
     split-view animation) skews `leading`.
   - Fallbacks: three-pane `240+480`, compact `220`, threadFocus `12`. If
     mode is three-pane but real list is narrower (or sidebar hidden), leading
     is too large → card shifts right. If mode is compact but list still
     visible briefly, leading is too small → card under list.
   - Asymmetry already exists even when metrics are “correct”: width subtracts
     2× side padding but chrome applies **no trailing pad** for inline, so the
     card is trailing-flush and has 24pt effective left inset inside the pane
     (12pt “lost” to the right). Mild on a wide pane; stacks with other errors
     on a narrow one.

3. **MEDIUM — `.frame(width:height:)` defaults to center alignment.**
   - `ComposeView` is framed to `cardWidth × cardHeight` with default
     **center** alignment, then `clipShape`. If any child’s ideal width
     exceeds `cardWidth` (footer `fixedSize` cluster, long unbroken tokens,
     format bar), the whole VStack can center and clip **both** edges.
   - Fits “uniform left cut” if right cut is less obvious (Send still near
     the visible right edge). Less likely alone (footer has a `Spacer`), but
     cheap to fix and should be done either way.

4. **LOW — Residual horizontal clip-view drift** on the body only.
   - Already mitigated in `ComposeBodyTextView.pinHorizontalScroll`. Does not
     explain From/Subject/header.

5. **LOW — Split min width 360** forces overflow on very narrow hosts when
   side-by-side is active. Secondary; screenshot looks like list+detail reply,
   not full-window split.

### Why “smaller window” triggers it

- Three-pane minimum is 1080pt; below that, compact swaps list↔detail, but
  mid widths + floating 620 + fallback 620 are the danger zone.
- Inline measured width tracks the pane and is usually fine **once metrics
  exist**; first frame, demotion, pop-out, and floating replies do not.
- Resize while compose is open can transiently publish zero/stale frames
  through PreferenceKeys (`reduce` keeps last non-tiny width, which can also
  **lag** a real shrink).

## Goals

1. Reply / compose card is **fully visible** at any window width the app
   allows (≥ `minWidth` 900 and down to sane manual shrink).
2. Inline card stays **inside the reading-pane column** (12pt side insets
   both sides), never under the list/sidebar.
3. Floating card stays **on-screen** (trailing pad preserved; width shrinks
   before it would clip).
4. Placement math is **pure + unit-tested** (narrow host, minWidth floor,
   fallback, host < preferred floating width, split still clamps).
5. No regression of Enter-key body pin, inline height reserve, or split
   livelock tests.

## Non-goals

- Redesign compose chrome / multi-window compose.
- Change default floating “measure” (620) on large windows.
- Fix unrelated body NSTextView typing jitter (already landed).

## Implementation sketch

### 1. Pure placement API (preferred)

Extend `ComposePlacement` with a single resolver used by `composeChrome`:

```swift
struct CardChrome: Equatable {
    var leading: CGFloat      // inset from host leading; 0 for floating/split
    var width: CGFloat
    var trailingPadding: CGFloat
    // height stays computed in ContentView from existing helpers
}

static let preferredFloatingWidth: CGFloat = 620
static let minUsableCardWidth: CGFloat = 280   // replace magic minWidth
static let floatingTrailingPadding: CGFloat = 16
static let floatingBottomPadding: CGFloat = 16

static func cardChrome(
    presentation: ComposePresentation, // already resolved (inline/float/split)
    minimized: Bool,
    host: CGRect,
    pane: CGRect,
    layoutMode: MailLayoutMode
) -> CardChrome
```

Rules (all widths ≥ 1 only when host is measured; otherwise keep today’s
fallback path but **still clamp**):

| Case | leading | width | trailing pad |
| --- | --- | --- | --- |
| minimized | 0 (trailing dock) | min(300, hostW − pads) | floating trailing |
| floating | 0 | min(620, max(minUsable, hostW − trailing − small leading margin)) | 16 |
| inline (metrics) | pane-relative leading, **clamped** so leading + width + trailingPad ≤ hostW | min(paneW − 2×12, available), never `max(min, …)` above pane | 12 (symmetric) |
| inline (fallback) | `fallbackLeadingInset`, then clamp as above | min(620, hostW − leading − trailingPad, …) | 12 |
| split | 0 (column owns x) | max(320, splitComposeWidth(host) − 2×12) but ≤ host column | split pad |

Critical pure invariants to test:

- `leading ≥ 0`
- `leading + width + trailingPadding ≤ max(host.width, width)` when host measured
- inline: card horizontal range ⊆ pane horizontal range (within 1pt) when both
  frames valid
- `width ≥ minUsable` only when host/pane can actually provide it; if host is
  pathologically narrow, shrink below minUsable rather than clip (prefer
  readable over overflowing)
- Prefer **shrinking width** over **negative leading**

Also fix `inlineMetrics`:

```swift
// before
let width = max(minWidth, pane.width - sidePadding * 2)
// after
let inner = pane.width - sidePadding * 2
let width = max(0, inner)   // caller clamps to min usable / host
```

Or keep a floor but document that `cardChrome` must min() against host free
space afterward — single choke point is better.

### 2. Wire `composeChrome`

Replace local `cardWidth` / `inlineLeading` assembly with `cardChrome(...)`.

```swift
ComposeView(request: request)
    .id(request.id)
    .frame(width: chrome.width, height: cardHeight, alignment: .topLeading)
    .background(...)
    .clipShape(...)
    .pmCardElevation(...)
```

Explicit **`.topLeading`** so an over-wide child never center-clips.

Keep the HStack leading spacer for inline (or switch to
`.padding(.leading, chrome.leading)` — same math). Apply
`chrome.trailingPadding` in the outer padding EdgeInsets (inline currently
uses 0 trailing — fix to 12 so side insets are symmetric).

### 3. PreferenceKey staleness (only if tests/manual still fail)

If clamping alone does not fix live resize:

- On `host.width` / `pane.width` shrink, recompute immediately (already via
  `onPreferenceChange`).
- Consider not retaining a **larger** previous width in `reduce` when the new
  value is smaller but still `> 1` (today: `if next.width > 1 { value = next }`,
  which is fine). Verify zero-frame flashes don’t revert to 620 mid-resize.

Do **not** change the “measure outside safeAreaInset” rule from `f1a9c0e`.

### 4. Tests

`ComposePlacementTests` (hostless):

1. `testFloatingWidthShrinksToHost` — host 500 → width ≤ 500 − trailing pad.
2. `testInlineMetricsNeverExceedsPane` — pane 200 → width ≤ 200 − 24.
3. `testInlineCardFitsHostWhenLeadingLarge` — leading + width + pad ≤ hostW.
4. `testInlineFallbackClampsOnCompactHost` — fallback path still on-screen.
5. `testMinimizedWidthClamps` — minimized 300 vs narrow host.
6. `testSplitStillClampsExistingRange` — existing split tests remain green.
7. `testSymmetricInlineSideInsets` — leading relative to pane equals trailing
   gap (12 / 12) when host/pane aligned.

No UI test required for v1 if pure math covers the overflow; optional
UITest later: open reply in demo at fixed narrow frame and assert
`composeInline` frame maxX ≤ window maxX and minX ≥ list maxX (fragile).

### 5. Manual smoke

- Demo mode, window ~900pt and ~1100pt (three-pane).
- Reply on open thread (inline): full From/To/Subject/context visible; 12pt
  gutter both sides of pane.
- Pop out → floating: card stays on screen; resize narrower while open.
- Forward (always floating) on three-pane: no list covering the card.
- ⇧⌘↩ split enter/exit: existing livelock UITest still green.
- Type Enter in body: no sideways jump regression.

## Implementation order

1. Add `CardChrome` + `cardChrome(...)` pure helpers + tests (red on current
   math if we encode “must fit host” against today’s formulas).
2. Fix `inlineMetrics` / floating width rules until tests green.
3. Wire `ContentView.composeChrome` + `.topLeading` frame alignment.
4. `make test` (or at least `ComposePlacementTests` + compose-related suite).
5. Fable review; fix findings; re-review to SHIP.

## Open questions for Fable

1. Is the screenshot better explained as **card under list** (placement) or
   **center-frame clip** (alignment), or both? Prefer a single choke-point fix.
2. Should floating shrink continuously below 620, or snap to a second tier
   (e.g. 620 → 420 → min)? Continuous min() is simpler.
3. When host is narrower than `minUsableCardWidth + pads`, is shrinking below
   min acceptable, or should we force floating full-bleed with horizontal
   scroll inside the card? Prefer shrink; avoid nested horizontal scroll.
4. Any known PreferenceKey global-frame pitfalls on recent macOS that should
   force a different positioning strategy (e.g. anchor to pane with
   `matchedGeometry` / background alignment instead of manual leading)?

## Success criteria

- Screenshot scenario: every glyph of “Replying to …”, From label, full
  subject, and body start is visible.
- Pure tests prove card horizontal range ⊆ host (and ⊆ pane for inline).
- Existing compose placement / split / esc / slash tests remain green.
- Fable SHIP on the implementation diff.
