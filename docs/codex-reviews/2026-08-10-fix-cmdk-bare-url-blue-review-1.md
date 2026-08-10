---
date: 2026-08-10 12:03
kind: self-review
target: branch fix/cmdk-bare-url-blue vs main
verdict: SHIP
reviewer: grok (self — user requested no fable)
reviewed_commit: 49e3d8362d86cd0075f0d44acd47dda0b10c2fdf
base: main @ d3d4427
tests: make test — 1374 passed, 5 skipped, 0 failures
focus: Cmd+K on bare URL opens link sheet instead of making selection blue
---

# Self-review — fix/cmdk-bare-url-blue (pass 1)

## Task

When composing, ⌘K on a selection that is already a bare URL/email should
make it blue (markdown hyperlink styling), not open the link sheet.

## Diagnosis

- Backlog (`docs/plans/2026-07-09-backlog-items.md` Task 2) specified
  immediate wrap: `foo.com` → `[foo.com](https://foo.com)` so the
  compose highlighter paints accent + underline.
- That short-circuit lived in `openLinkSheet()` using `selfLink` +
  `applyLink`.
- Commit `43eb42d` (2026-08-03) regressed it: bare-URL ⌘K started
  opening the sheet (and empty-label apply became a no-op via
  `shouldWrap` / `bareURLApply`), so the selection never turned blue.

## Change

1. `ComposeLinks.applySelfLink(in:selection:)` — pure helper that wraps
   a self-linkable selection as `[selection](href)` or returns nil.
2. `ComposeView.openLinkSheet()` — on non-empty selection that does not
   partially overlap an existing markdown link, call `applySelfLink`
   and return without showing the sheet.
3. Tests for bare host / https / email / paren-wrapped label, and
   rejections for plain words and existing markdown.

Unchanged:

- Caret inside existing `[text](url)` still opens the edit sheet.
- Ordinary text still opens the insert sheet.
- Partial overlap of a markdown link still falls back to the sheet.
- Sheet apply path (`bareURLApply`) left intact for non-short-circuit
  cases.

## Findings

None. Restores documented intended UX; pure path unit-tested; full suite green.

## Verdict

**SHIP**
