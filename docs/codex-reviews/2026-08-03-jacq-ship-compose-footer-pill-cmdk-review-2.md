---
date: 2026-08-03 12:07
kind: fable-iterate review
implementer_model: grok-4.5
grok_jobs: ship-20260803T120031-15282, rescue-20260803T120331-16889
reviewed_commit: fa1e1ca (on 43eb42d)
branch: jacq/ship-20260803T120031-15282
verdict: SHIP
---

# Review — compose footer clamp, quote-pill hug, ⌘K bare-URL

Scope: three user-reported compose bugs.

1. **Send/footer row off-page on short windows.** Floating card height was a
   fixed `preferredFloatingCardHeight = 500` regardless of host height. Fix:
   `ComposePlacement.effectiveFloatingCardHeight(hostHeight:)` clamps to
   host − bottom pad − 12pt top gutter, floor 260, 500 when unmeasured/tall.
   Wired into `ContentView.composeChrome` floating case only (split/pane/
   inline untouched). Unit tests cover tall/short/unmeasured/floor.

2. **"…" pill floating at card bottom.** With no collapsed quote the editor
   max height was `.infinity`, flexing to fill the card and pushing the
   inlined-quote collapse pill to the bottom. Fix: cap max at
   `max(noQuoteMin, contentHeight + contentSlack)`; editor still scrolls
   internally when the card is shorter. A single trailing
   `Spacer(minLength: 0)` (guarded by `!slashActive`) now covers all three
   branches — collapsed pill, inlined pill, and plain new mail — so the
   footer stays pinned at the card bottom.

3. **⌘K on bare URL doubled it as `[url](url)`.** Bare URLs already
   auto-link on send via `htmlFragment`. ⌘K on a bare-URL selection now
   opens the sheet with the URL prefilled and empty display text.
   `ComposeLinks.bareURLApply(label:href:existingHref:)` decides on apply:
   empty/same-as-URL label + unchanged href → no-op; empty label + changed
   href → replace selection with the normalized bare URL; distinct label →
   markdown wrap as before. Caret-in-existing-link edit flow unchanged.

## Review pass 1 (43eb42d) — NOT READY

- Plain new mail lost its flexible element → footer floated mid-card.
- `applyLink` silently discarded a URL edited in the sheet when the label
  was left empty (`shouldWrap` false for any empty label).

Both fixed in rescue commit fa1e1ca; pure decision logic moved into
`ComposeLinks.bareURLApply` with tests.

## Review pass 2 (fa1e1ca) — SHIP

- Full diff re-read: no unrequested changes, style matches, comments
  explain constraints not history.
- `make test` run by supervisor outside Grok's sandbox (Grok's runs failed
  on sandbox dep resolution, commits used `--no-verify`):
  **1263 tests, 0 failures** (5 skipped, pre-existing).
