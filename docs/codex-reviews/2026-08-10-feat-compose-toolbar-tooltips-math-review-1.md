---
date: 2026-08-10 20:10
kind: review
target: branch diff against main (feat/compose-toolbar-tooltips-math-20260810T200200)
verdict: ship-it
codex_session_id:
job_id: review-20260810T200724-19345
duration: ~3m
invoked_from: /Users/ronboger/mishmail/.worktrees/compose-toolbar-20260810T200200
git_branch: feat/compose-toolbar-tooltips-math-20260810T200200
git_head: a68d98e
diff_size: 8 files vs main
focus: compose toolbar tooltips, LaTeX HTML, hideable buttons, link clip
review_model: claude-fable-5
review_effort: low
---

# Review pass 1 (pre-fix)

id:	review-20260810T200724-19345
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/compose-toolbar-20260810T200200
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260810T200724-19345/output.log
---
Permission deny rule "MultiEdit" matches no known tool — check for typos.
All 22 selected tests pass (`** TEST SUCCEEDED **`, MarkdownTests + ComposeToolbarVisibilityTests). Review of `main...HEAD` (single commit a68d98e, 8 files):

## Findings

**Medium**

1. **`x^\alpha` mis-renders** — `Markdown.swift:276-287` (renderMathExpr, the `^`/`_` branch). When the script argument is a bare command (`e^\pi`, `x^\alpha`, common LaTeX), the branch consumes only the single `\` character as the body, leaving `pi` behind as literal text. Output becomes `e<sup>\</sup>pi` instead of `e^π`. Fix: if the char after `^`/`_` is `\`, parse a full command as the body before falling back to single-char.

**Low**

2. **Dead/incorrect spacing-command entries** — `Markdown.swift` mathCommands has `" ": " "` and `",": " "`, but `\,` and `\ ` never reach the map: the `!next.isLetter` branch (line ~210) emits the literal char first. `\,` renders as a comma in the output instead of a thin space. The two map entries are unreachable.
3. **`\frac` without braces** — `\frac ab` (valid LaTeX single-token form) renders an empty stacked fraction `()/()` followed by `ab`. Rare in email; acceptable, but an empty fraction box in HTML looks broken.
4. **Hiding Snippets silently removes ⌘/** — `ComposeView.swift`: `keyboardShortcut("/", .command)` is inside the `if composeToolVisible(.snippets)` block. The Settings footer only promises hidden *format* shortcuts keep working, so the text is technically accurate, but the shortcut loss isn't surfaced anywhere.
5. **Stale comment** — `Markdown.swift:401` "Longer names first so `\rightarrow` wins over `\to`" sits on a dictionary; lookup is by fully-parsed command name, so ordering is irrelevant. Harmless, misleading.
6. **Pre-existing test warnings** (not from this diff, read-only so left alone): unused-mutation `var`→`let` warnings in DatabaseMigrationTests.swift:272, LocalPruneTests.swift:89, MCPHTTPTests.swift:54, PriorityCandidatesTests.swift:212/218, ThreadDetailMirrorTests.swift:47.

## Task coverage

- **Tooltips**: done — `.help(item.help)` on every footer/format button with shortcuts included; VoiceOver labels are the bare names. Good.
- **Clean LaTeX HTML**: done — stacked fractions, real `<sup>/<sub>`, proper HTML escaping (verified by `testMathEscapesHTMLInBody`; escapeText handles `&` first, so no double-escape issue). Unmatched `}` skipped, unclosed `{` tolerated, nested braces handled with escaped-brace skip in `takeBraceGroup`.
- **Hideable buttons**: done — pure `ComposeToolbarVisibility` helpers, unknown tokens preserved for forward compat, Settings section with reset button, format bar collapses fully when all format items hidden. Tested.
- **Link button cut-off**: addressed two ways — fixed 24×22 cell on footer buttons and removal of the duplicate trailing link icon from the format strip. Visual fix; not verifiable from tests, plausible from the code.

## Open questions

- Was the second link icon in the format strip intentionally removed as UX (not just to fix clipping)? Muscle memory for users clicking link at the strip's end now hits Math.
- Should hiding `.attach` be allowed given it's the only discoverable attach path besides drag-drop? (User opt-in, so probably fine.)

## Suggested fixes (not applied — read-only)

- In the `^`/`_` branch, when the next char is `\`, parse `\` + letter-run (plus optional brace group for `\sqrt`-like) as the body.
- Handle `\,`/`\ ` in the single-char-escape branch (emit thin space / space) and drop the dead map entries.
- Delete the stale "Longer names first" comment.

## Verdict

**SHIP** — the medium finding (`x^\alpha`) degrades gracefully to visible-but-ugly output rather than corrupting the message, everything else is polish, and the targeted tests pass.

## Resume

```bash
# jacq-claude job (not codex session)
jacq-claude result review-20260810T200724-19345
```
