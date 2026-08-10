---
date: 2026-08-10 12:07
kind: self-review
target: branch fix/cmdk-bare-url-blue-v2 vs main
verdict: SHIP
reviewer: grok (self — user requested no fable)
focus: Preserve Aug 3 bare-URL Cmd+K improvements while keeping blue hyperlink affordance
tests: make test — 1374 passed, 5 skipped, 0 failures
---

# Self-review — fix/cmdk-bare-url-blue-v2 (pass 1)

## Context

v1 (`49e3d83`) restored immediate `[selection](href)` wrap on ⌘K so bare
URLs painted blue. That re-regressed the Aug 3 fix (`43eb42d` / `fa1e1ca`):
wrapping bare URLs as `[url](url)` doubles plain text, and bare URLs
already auto-link on send via `htmlFragment`.

User asked not to lose that Aug 3 improvement.

## Design (both intents)

| Need | Solution |
|------|----------|
| Blue / clearly a hyperlink | Paint autolink spans blue+underline in the editor always |
| No `[url](url)` doubling | Do not wrap bare URL on ⌘K |
| Optional display text | ⌘K opens sheet prefilled with href, empty label (Aug 3) |
| Sheet apply semantics | Keep `bareURLApply` (noOp / replaceBare / wrap) |

## Change

1. `ComposeLinks.editorLinkStyleRanges(in:)` — UTF-16 ranges for markdown
   links **and** bare autolinkable hosts/URLs (same as `htmlFragment`).
2. `ComposeBodyEditor.highlight` uses those ranges instead of a regex that
   only matched markdown links.
3. `openLinkSheet` restored to Aug 3: bare self-link → sheet, no wrap.
4. Removed `applySelfLink` (the v1 wrap helper).

## Findings

None. Aug 3 decision logic and tests unchanged; new style-range tests
cover bare host, https, markdown, no double-count, plain words, and
non-linkable hosts (`setup.sh`).

## Verdict

**SHIP**
