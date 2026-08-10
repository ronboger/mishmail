---
date: 2026-08-10 12:10
kind: self-review
target: branch fix/cmdk-bare-url-complete vs main
verdict: SHIP
reviewer: grok (self — user requested no fable)
tests: make test — 1380 passed, 5 skipped, 0 failures
focus: Finish Cmd+K bare-URL — no sheet, keep Aug 3, blue hyperlinks
---

# Self-review — fix/cmdk-bare-url-complete (pass 1)

## Status of prior attempts

| Version | Blue | No sheet on ⌘K | No `[url](url)` for autolinks |
|---------|------|----------------|------------------------------|
| v1 wrap | via wrap | yes | **regressed** |
| v2 paint only | always | **no** (still sheet) | yes |
| **complete** | always + wrap when needed | **yes** | **yes** |

## Final behavior

1. **Autolink bare host/https** (`foo.com`, `https://…`): already blue via
   `editorLinkStyleRanges`; ⌘K → `alreadyLinked` (no sheet, no body change).
2. **Link-shaped but not autolink bare** (`a@b.com`, `(foo.com)`): ⌘K →
   immediate markdown wrap (blue + real link), no sheet.
3. **Ordinary text / partial markdown overlap / caret in markdown link**:
   sheet unchanged.
4. **`bareURLApply`**: still used by sheet apply for any remaining bare
   selection path (empty label no-op / replaceBare / wrap).

## Findings

None. Pure `bareURLCmdK` / `isAutolinkBareSelection` unit-tested; full
suite green.

## Verdict

**SHIP**
