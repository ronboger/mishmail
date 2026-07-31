---
date: 2026-07-31 15:56
kind: review
target: branch fix/hebrew-english-bidi-backlog vs main
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260731T155450-96529
reviewed_commit: 90483f24245f291ef178b97f16677750f907aee1
invoked_from: /Users/ronboger/mishmail/.worktrees/hebrew-english-bidi-backlog
git_branch: fix/hebrew-english-bidi-backlog
git_head: 90483f24245f291ef178b97f16677750f907aee1
---

# Fable Review (backlog pass 2)

## Prompt

```
[jacq-claude] Mode: READ-ONLY. Do not modify project files. Analyze and report only.

You are a careful code reviewer. Focus on correctness, security, edge cases, and test gaps. Be specific (file:line).
Compare against git ref 'main' (diff / log as needed).
Focus: Re-review pass 2 after fixing H1/H2/M1/M3 from backlog review-1.

Fixes:
- bareHostRegex lookbehind (?<![\w@.]) — emails not shredded
- isLinkableHost TLD allowlist gates autolink; non-linkable hosts still get span dir=ltr
- phone regex no longer matches newlines
- ComposeSubjectField updates currentEditor direction while focused
- Tests for email, setup.sh, forms.gov.il, phone newline

Review complete diff vs main. SHIP or NOT READY.

Deliver:
1. Findings ordered by severity with evidence
2. Open questions
3. Suggested fixes (do not apply unless write mode was requested)

Do not modify files unless explicitly told to write.
```

## Verbatim result

```
## Re-review pass 2 — verdict: **SHIP** (with two minor follow-ups)

All four fixes from review-1 land correctly. I verified each against the diff and traced surrounding behavior; nothing blocking remains.

### Verified fixes

- **H1 emails** — `bareHostRegex` lookbehind `(?<![\w@.])` (TextDirection.swift:79) correctly blocks `ron@gmail.com` → `gmail.com`; test `testEmailDoesNotYieldBareHost` asserts both no-span and no-anchor.
- **H2 over-linkify** — `isLinkableHost` TLD allowlist gates `bareURLMatches` (ComposeLinks.swift:326-340); non-linkable hosts (`setup.sh` fails denylist, `foo.bar` fails allowlist) still get `<span dir="ltr">` via `plainChunkHTML`. Tests cover both.
- **M1 phone newlines** — phone class is now `[\d \t().-]` (no `\n`); `testPhoneDoesNotSpanNewline` confirms no cross-line merge, so no `\n` is ever swallowed inside a span in `htmlFragment`.
- **M3 subject** — `applyDirection` now pushes `baseWritingDirection`/`alignment` onto `field.currentEditor()` (ComposeView.swift:2081-2085), so direction updates take effect while focused, not just after blur.

### Findings

**M — bare-host isolate/anchor drops the path and port.** `bareHostRegex` puts `(?::\d{2,5})?(?:/…)?` *outside* capture group 1, and both `ltrIsolateSpans` and `bareURLMatches` use `match.range(at: 1)` (TextDirection.swift:79-82, 156-162). So `see forms.gov.il/he/service now` isolates and links only `forms.gov.il`; `/he/service` is left as plain text — the anchor points at the wrong URL and the path segment is un-isolated in RTL prose (the exact shredding this branch fixes for scheme URLs). The doc comment ("optional `:port` / path") claims the opposite. Fix: widen group 1 to include port+path, keep `hostTLD(of:)` stripping (it already handles `/` and `:port`). No test covers a bare host with a path — add one.

**L — overlap resolution can theoretically leave overlapping spans.** In `ltrIsolateSpans` (TextDirection.swift:171-186), when a higher-priority span replaces `accepted[idx]` in place, the replacement's (possibly different) extent is never re-checked against other already-accepted spans. Hard to trigger with current kinds (iteration is location-ordered), but the invariant "non-overlapping" in the doc comment isn't enforced. Cheap hardening: after replacement, drop any other accepted span the replacement overlaps.

**Nits (no action required):**
- `phoneRegex` has a leading lookbehind but no trailing boundary — `1234567abc` isolates just `1234567`, splitting a token. Harmless.
- A host glued to Hebrew (`שלוםexample.com`) gets no isolation because Hebrew letters are `\w` and trip the lookbehind. Acceptable conservatism.
- `ComposeSubjectField.updateNSView` sets `stringValue` while focused if the binding diverges — could clobber IME marked text for CJK input; irrelevant for Hebrew/English but worth remembering.
- `.frame(height: 22)` hardcodes the field height against a 14pt semibold font; fine today, brittle if font changes.

### Open questions

1. Is bare-host path linkification in scope for this branch, or intentionally deferred? The regex clearly *tried* to include it — looks like an oversight, not a decision.
2. `blocks(in:)` now preserves *leading* blank runs too, so a body starting with blank lines emits leading `<div><br></div>` spacers. Intended? (Previously dropped.)

### Suggested fixes (not applied — read-only)

1. `bareHostRegex`: move port/path into group 1 — `((?:label\.)+[a-z]{2,24}(?::\d{2,5})?(?:/[^\s<>\[\]()\"']*)?)` — and add tests `testBareHostWithPathIsolatedAndLinked` asserting span text and `href="https://forms.gov.il/he/service"`.
2. Overlap resolver: after `accepted[idx] = span`, remove other accepted spans overlapping `span`.

Neither blocks merge; the path issue is a scoped follow-up rather than a regression (main didn't linkify bare hosts at all).
```
