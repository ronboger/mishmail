---
date: 2026-07-31 15:59
kind: review
target: branch fix/hebrew-english-bidi-backlog vs main
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260731T155703-98192
reviewed_commit: 5ac718e9bc27952b3138cc3ddc86f2f57128efcc
invoked_from: /Users/ronboger/mishmail/.worktrees/hebrew-english-bidi-backlog
git_branch: fix/hebrew-english-bidi-backlog
git_head: 5ac718e9bc27952b3138cc3ddc86f2f57128efcc
---

# Fable Review (backlog pass 3)

## Prompt

```
[jacq-claude] Mode: READ-ONLY. Do not modify project files. Analyze and report only.

You are a careful code reviewer. Focus on correctness, security, edge cases, and test gaps. Be specific (file:line).
Compare against git ref 'main' (diff / log as needed).
Focus: Re-review pass 3 after fixing bare-host path capture (group 1 includes :port and /path) and greedy non-overlapping span accept. Review complete diff vs main. SHIP or NOT READY.

Deliver:
1. Findings ordered by severity with evidence
2. Open questions
3. Suggested fixes (do not apply unless write mode was requested)

Do not modify files unless explicitly told to write.
```

## Verbatim result

```
## Re-review pass 3 — verdict: **SHIP** (with minor follow-ups)

The two fixes under review are correct:

- **Bare-host group 1 now includes `:port` and `/path`** (`TextDirection.swift:78` regex) and `hostTLD(of:)` strips path-then-port before TLD checks (`TextDirection.swift:191-207`). `testBareHostWithPathIsolatedAndLinked` covers the full-token anchor. The port strip (`lastIndex(of: ":")` after slash-strip, all-digits guard) is correct.
- **Greedy non-overlapping accept** (`TextDirection.swift:160-176`): sort by priority → length → location, accept only if no overlap with previously accepted. This fixes the residual-overlap problem from the replace-based approach. `rangesOverlap` half-open math is correct.

### Findings (by severity)

**1. LOW — Dotted email local-part still yields a host span.**
`bareHostRegex`'s lookbehind `(?<![\w@.])` blocks the *domain* side of `ron@gmail.com`, but there is no negative lookahead, so `ron.boger@gmail.com` matches `ron.boger` as a `.host` candidate (TLD "boger" passes plausibility). Result: `<span dir="ltr">ron.boger</span>@gmail.com` — the email's LTR run is split mid-token in RTL prose, arguably worse than no isolation. Not linkified (TLD not allowlisted), so isolation-only damage. `testEmailDoesNotYieldBareHost` only covers a dot-free local part.
*Fix:* append `(?![\w@])`-style lookahead — specifically `(?!@)` after the capture — to `bareHostRegex`.

**2. LOW — Markdown bodies get no host/phone isolation.** `Markdown.inlineHTML` linkifies scheme URLs only (`Markdown.swift:490`); bare hosts (`forms.gov.il`) and phones inside a Hebrew markdown paragraph are neither anchored nor `dir="ltr"`-spanned, while the identical plain-text body would be. Asymmetry, acceptable as a documented follow-up.

**3. INFO — Phone regex has no trailing lookahead.** `(?<![\w])(\+?\d[\d \t().-]{5,}\d)` matches `1234567` inside `1234567abc` (span ends mid-token). Also trailing trim can leave a separator terminal, e.g. `1234567-.` → trims `.`, leaves `1234567-`. Cosmetic; digitCount re-check keeps correctness.

**4. INFO — `blocks(in: "")` returns `[.blanks(1)]`**, not `[]` (`""`.split gives `[""]`, count 1, no trailing-drop). Unreachable in practice (`authoredHeadHTML` guards empty; `paragraphs` compactMap drops it), but the `plainAuthoredHTML` `blocks.isEmpty` fallback branch is now effectively dead. Worth a doc comment or guard.

**5. INFO — Perf:** `plainChunkHTML` recomputes `ltrIsolateSpans(in: plain)` for every non-link chunk of the same paragraph (`ComposeLinks.swift:222`), and `htmlFragment` already computed it once via `bareURLMatches`. Three regex passes × (1 + chunks) per paragraph. Fine for email-sized bodies; hoist if the editor highlighter ever shows lag (highlighter path uses `ltrIsolateNSRanges` once per keystroke, which is fine).

### Verified non-issues
- Linkable host overlapping a markdown link: dropped from bare anchors via `occupied` in `nonOverlappingLinkSpans` (ComposeLinks.swift:281-296), and never reaches `plainChunkHTML` (not in a plain chunk). No double-linkify.
- `plainChunkHTML` host filter vs `bareURLMatches` linkify use the same `isLinkableHost` predicate — a linkable host always becomes an anchor, non-linkable always a span; no gap where neither fires (`normalizeURL` can't return nil for a dotted host).
- Phone spans can't contain `\n` (char class excludes it), so no `<br>` loss inside spans; `testPhoneDoesNotSpanNewline` covers it.
- IPs (`192.168.1.10`) fall through host (letters-only TLD) to phone kind → still isolated. Ports (`:8080`, 4 digits) can't spawn competing phone spans.
- `ComposeSubjectField`: `stringValue != text` guard prevents cursor reset on echo; direction applied to both cell and live field editor — correct.
- Overlap priority url > host correctly suppresses the host candidate inside `https://foo.com/...` (lookbehind passes after `/`, but URL span wins).

### Open questions
1. Is the missing host/phone isolation in the markdown path (finding 2) an accepted follow-up, or should it block?
2. Intentional that dates like `2026-07-31` get phone-kind LTR spans? (I'd say yes — dates shred under UBA too — but it changes rendered HTML for any RTL mail mentioning a date.)

Note: I did not build/run the test suite (read-only mode); review is static. The test additions look like they compile and pass against the shown implementations.
```
