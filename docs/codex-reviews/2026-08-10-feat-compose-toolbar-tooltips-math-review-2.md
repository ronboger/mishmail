---
date: 2026-08-10 20:14
kind: review
target: branch diff against main (feat/compose-toolbar-tooltips-math-20260810T200200)
verdict: ship-it
codex_session_id:
job_id: review-20260810T201212-22398
duration: ~2m
invoked_from: /Users/ronboger/mishmail/.worktrees/compose-toolbar-20260810T200200
git_branch: feat/compose-toolbar-tooltips-math-20260810T200200
git_head: 3117c91
diff_size: 8+ files vs main (2 commits)
focus: re-review after bare-script fix
review_model: claude-fable-5
review_effort: low
---

# Review pass 2 (post-fix)

id:	review-20260810T201212-22398
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/compose-toolbar-20260810T200200
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260810T201212-22398/output.log
---
Permission deny rule "MultiEdit" matches no known tool — check for typos.
All 1400 unit tests pass (`make test`, 0 failures, 1 skipped). Review of the branch's actual changes (base `7032bfe`; the raw `git diff main` also shows main's newer recipient-chip work as spurious deletions — ignore those, the branch doesn't touch `AddressField.swift`).

## Findings

**Confirmed fixed — medium `x^\alpha` / bare-script issue.** In `Sources/MishMail/Support/Markdown.swift` (the `^`/`_` branch, ~line 505), a bare `\name` after a script char is now consumed whole: `e^\pi` → body `\pi` → `mapScript` returns nil (`\` has no unicode form) → `<sup>π</sup>` in HTML, `e^(π)` in plain text. Same path handles `x^\alpha` → `<sup>α</sup>`. Covered by `testMathToHTMLFractionAndScripts` (`e^\pi`, `x_\alpha` assertions), and the run above shows them passing. Correct.

**Low — escaped braces inside a bare-script brace group.** The inline depth scan in the `^`/`_` bare-command branch (Markdown.swift, the `while j < input.endIndex, depth > 0` loop) counts `{`/`}` without skipping `\{`/`\}`, unlike `takeBraceGroup` which does. `e^\text{a\}b}` mis-splits the group. Contrived input, readable-fallback context — cosmetic only, no injection risk since output is still escaped.

**Low — `\,` renders as a full `&nbsp;` rather than a thin space.** The commit message says "thin spaces," but `case ",", ":", ">"` all emit `&nbsp;` (and `\;` two of them). If fidelity matters, `&#8239;` (narrow no-break space) is closer. Cosmetic.

**Low — untested: ⌘/ on the zero-size hidden Snippets button.** `ComposeView.swift:~1170` keeps the shortcut via an `EmptyView`-labeled, 0×0, `accessibilityHidden` button. `.keyboardShortcut` on macOS generally fires regardless of layout size, but nothing automated covers it and I could not verify it in-app here.

**Notes (no action needed):**
- XSS: `mathToHTML` escapes every literal char through `ComposeLinks.escapeText` + quote escaping; `testMathEscapesHTMLInBody` confirms `<script>` is neutralized. Fraction/sup interpolations only receive already-escaped strings.
- `hiddenSet` preserving unknown tokens is a good forward-compat choice; toggle round-trip and sorted encoding are tested.
- The all-format-hidden case correctly drops the whole `ComposeFormatBar`, and the divider logic degrades cleanly when either side is empty.

## Open questions

- Does ⌘/ actually fire from the zero-size hidden button in the running app? Worth one manual check before release.
- Rebase onto main will be needed (main added the chip-select commits); no file overlap with this branch, so it should be clean.

## Suggested fixes (not applied — read-only)

1. In the bare-script brace scan, skip a character after `\` (mirror `takeBraceGroup`'s escape handling).
2. Optionally use `&#8239;` for `\,`/`\:`/`\>`.

## Verdict

**SHIP.** The prior findings are fixed and test-covered; remaining items are low-severity cosmetics and one untested-but-likely-fine shortcut path.

## Resume

```bash
jacq-claude result review-20260810T201212-22398
```
