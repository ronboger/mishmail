# Side-by-side compose (draft ⇄ conversation split)

**Date:** 2026-07-21
**Status:** Implemented

## Problem

While drafting a reply you constantly need the original email: the inline
dock shows the conversation above a 460 pt composer, and the floating card
covers it. There was no way to give *both* the draft and the source
conversation real estate at once, and no full-window drafting surface.

## Approaches considered

1. **Full-window split via the compose overlay** *(chosen)* — a third
   `ComposePresentation` case. The mailbox layout swaps to a two-column
   canvas (conversation left, empty right column) and the existing
   window-level compose overlay pins the composer card into the right
   column. Because the overlay already hosts one `ComposeView` identity for
   floating/inline flips, entering/leaving split keeps the typed body for
   free.
2. Vertical split inside the reading-pane column — cramped at three-pane
   widths; doesn't satisfy "take up the whole screen".
3. Separate compose window — the app is a single `WindowGroup`; multi-window
   would fork the overlay/identity model and the key-monitor routing.

## Design

- `ComposePresentation.split` (Support/ComposePlacement.swift). Placement
  math is pure and tested: `splitComposeWidth(hostWidth:)` = half the
  window clamped to [360, 640]; the conversation absorbs the rest.
  `resolvedPresentation` passes `.split` through untouched (it ignores the
  reading-pane height).
- `MailStore.enterSplitCompose()` requires `composeRequest.replyTo != nil`
  (replies, forwards, reopened reply drafts — a fresh compose or draft-only
  thread has no conversation to show). `exitSplitCompose()` recomputes the
  normal placement via `ComposePlacement.preferred`, so you land back
  inline when the thread is still open, floating otherwise.
  `thread(withId:)` resolves the left column from memory, then DB, so the
  split survives list reloads/view switches.
- ContentView renders `splitComposeLayout` instead of the NavigationSplitView
  modes while split is active and compose is not minimized. Left column:
  `ThreadDetailView(splitMode: true)` for `composeRequest.boundThreadId` —
  back control reads "Exit Side by Side", prev/next are hidden (selection is
  decoupled from the bound thread). Right column: reserved width; the
  overlay `composeChrome` sizes the composer to fill it full-height with a
  12 pt gutter.
- Entry/exit: ⇧⌘↩ toggle (works while typing — handled before the compose
  passthrough in the key monitor; plain ⌘↩ now explicitly excludes ⇧),
  a `rectangle.split.2x1` button in the compose header, and the left
  column's toolbar exit button. Esc ladder (ContentView key monitor via
  `ComposeEsc.intent`, not monitor install order): dismiss `/` picker → close
  command palette → exit split first (draft stays open) → next Esc saves &
  closes the draft. The split header's `.cancelAction` remains a backup when
  focus is not in NSText. Minimizing pauses split (mailbox returns); expanding
  the strip restores it.

## Testing

- `ComposePlacementTests`: split width clamping, `.split` pass-through in
  `resolvedPresentation`, `showsInline == false` for split.
- Full suite (709 tests) green; manual smoke via `make run`.
