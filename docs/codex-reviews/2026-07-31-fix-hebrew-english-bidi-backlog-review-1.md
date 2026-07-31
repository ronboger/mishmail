---
date: 2026-07-31 15:53
kind: review
target: branch fix/hebrew-english-bidi-backlog vs main
verdict: NOT READY
model: claude-fable-5
effort: low
job_id: review-20260731T155108-93291
reviewed_commit: bb6451775bca6d70d98b5e21939e81f899a4a233
invoked_from: /Users/ronboger/mishmail/.worktrees/hebrew-english-bidi-backlog
git_branch: fix/hebrew-english-bidi-backlog
git_head: bb6451775bca6d70d98b5e21939e81f899a4a233
---

# Fable Review (backlog pass 1)

## Prompt

```
[jacq-claude] Mode: READ-ONLY. Do not modify project files. Analyze and report only.

You are a careful code reviewer. Focus on correctness, security, edge cases, and test gaps. Be specific (file:line).
Compare against git ref 'main' (diff / log as needed).
Focus: Review the complete BiDi backlog diff vs main on branch fix/hebrew-english-bidi-backlog.

Task: implement remaining Fable follow-ups from Hebrew/English BiDi:
1. Bare hostnames isolated + autolinked (forms.gov.il)
2. Phone/long-ID isolation (≥7 digits) in editor + HTML spans
3. Subject field baseWritingDirection (ComposeSubjectField NSTextField)
4. Markdown per-block dir
5. Shared bareURLRegex via TextDirection for ComposeLinks
6. Multi blank-line fidelity + whitespace-only lines as blanks

Check correctness, false positives (README.md as host?), regressions, test coverage.
Give findings by severity; finish with SHIP or NOT READY.
List any remaining true backlog vs done.

Deliver:
1. Findings ordered by severity with evidence
2. Open questions
3. Suggested fixes (do not apply unless write mode was requested)

Do not modify files unless explicitly told to write.
```

## Verbatim result

```
Sandbox blocks running the test suite, so this is a static review of the full diff vs `main` (7 files, +481/−105).

# BiDi Backlog Review — `fix/hebrew-english-bidi-backlog` vs `main`

## Findings by severity

### HIGH

**H1. Bare emails get shredded into bogus hostname links.**
`bareHostRegex` (TextDirection.swift:76) has no guard against a preceding `@`. In `ron@gmail.com`, `\b` holds between `@` and `g`, so `gmail.com` is matched as a `.host` span. `bareURLMatches` (ComposeLinks.swift:313-322) now feeds `.host` spans into `normalizeURL` → an anchor `https://gmail.com` is wrapped around only the domain half of the address in outgoing HTML. On `main`, plain-text emails were not linkified at all — this is a new regression, in both `htmlFragment` output and the editor link layer (`nonOverlappingLinkSpans`, ComposeLinks.swift:279). Fix: negative lookbehind `(?<![\w@.])` (or drop candidates preceded by `@`). No test covers `text with ron@gmail.com`.

**H2. Denylist-based bare-host detection will autolink arbitrary `word.word` tokens — and those become live anchors in sent mail.**
`isPlausibleBareHost` accepts any TLD of 2–24 ASCII letters not in the file-extension denylist (TextDirection.swift:84-95, 236-256). So `setup.sh` (`sh` is a real ccTLD, not denylisted), `file.ext`, `foo.bar`, `asp.net`, `notes.org`, `a.bc` all pass and get **autolinked** in outgoing HTML (`bareURLMatches` no longer distinguishes "isolate-only" from "linkify"). The `IsolateKind` doc comment even says host = "isolate always; linkify when safe" — but the code linkifies every host unconditionally. `README.md` specifically is handled (test at TextDirectionTests: `testFileExtensionIsNotBareHost`), but the denylist is inherently leaky. Suggested fix: keep isolation broad, but gate *linkification* on an allowlist of common TLDs (`com,org,net,il,gov.il,io,co,dev,…`) or require `www.`/≥3 labels; i.e. use `span.kind == .host && isLinkableTLD(...)` in `bareURLMatches`.

### MEDIUM

**M1. Phone regex spans whitespace including newlines and sentence boundaries.**
Pattern `(?<![\w])(\+?\d[\d\s().-]{5,}\d)` (TextDirection.swift:100):
- `\s` matches `\n`, so `…2026\n123 4567…` merges into one phone span across lines. Worse, `plainChunkHTML` (ComposeLinks.swift:236) emits span content via `escapeText(text)` **without** the `\n → <br>` replacement, so a newline inside a matched span is silently dropped from the HTML. Restrict the class to `[ \t]` (or `[\d ().-]`).
- `.` and space inside the class let two unrelated numbers merge across a sentence: `"בשנת 2026. 1948 היא"` → one `.phone` span `2026. 1948` (8 digits ≥ 7), forcing an LTR run across a sentence break in RTL prose. Consider disallowing `. ` (dot-space) sequences or capping consecutive separators.

**M2. Overlap resolution can replace an accepted span without re-checking overlaps against the rest of `accepted`.**
TextDirection.swift:150-170: when a higher-priority span replaces `accepted[idx]`, the replacement may now overlap a *different* already-accepted span (e.g. a long URL replacing a host that sat between two phone spans), yielding overlapping output ranges. Downstream (`plainChunkHTML`, editor attributes) assumes disjoint, sorted ranges. Unlikely in practice but cheap to harden: rebuild via a single sweep (sort by priority desc, then greedily accept non-overlapping).

**M3. Subject field direction may not apply to the active field editor.**
`applyDirection` sets `field.baseWritingDirection` (ComposeView.swift:2060-2072), but while the field has focus, NSTextField text is drawn by the shared field editor (NSTextView); changing the cell's `baseWritingDirection` mid-edit does not reliably update the live editor until focus cycles. If `field.currentEditor()` is non-nil, also set `baseWritingDirection`/`alignment` on it (or `defaultParagraphStyle`). Manual verification needed: type Hebrew from an empty subject and confirm direction flips *while typing*, not only after blur.

### LOW

**L1. `updateNSView` resets `stringValue` on external changes without preserving selection** (ComposeView.swift:2051-2057). Fine for the reply-prefill case; caret jumps only if the binding is mutated externally mid-edit — currently no such path. Note only.

**L2. `blocks(in:)` keeps leading/trailing blank runs** (documented, TextDirection.swift:265) — so a body beginning with a blank line now emits a leading `<div><br></div>` in sent HTML, whereas `main` dropped it. Probably desired ("fidelity"), but it's a visible behavior change; no test pins leading/trailing behavior.

**L3. Markdown bodies are inconsistent with plain bodies:** markdown `inlineHTML` autolinks only scheme URLs (shared `bareURLRegex`, Markdown.swift:490) — no bare-host autolink and no phone `dir=ltr` spans inside markdown blocks. Given H2, this conservatism is arguably correct, but it's an intentional gap worth recording as backlog, not "done".

**L4. `isPlausibleBareHost` port-strip edge:** trailing bare `:` (empty suffix) satisfies `allSatisfy` vacuously and strips (TextDirection.swift:243-246). Harmless — regex requires `\d{2,5}` for a port anyway, and `:` isn't matched otherwise.

**L5. Perf note:** `plainChunkHTML` calls `ltrIsolateSpans(in: plain)` once per chunk (per link gap), i.e. O(links × body) regex passes at send time. Fine for email sizes; compute once in `htmlFragment` and pass down if bodies get large. The editor highlighter path now runs three regexes per keystroke (ComposeBodyEditor.swift:489) — acceptable, but was one.

## Test gaps
- No test for email addresses in plain bodies (H1) — add `htmlFragment(from: "כתבו ל ron@gmail.com")` asserting no `https://gmail.com` anchor.
- No negative tests for host FPs beyond `README.md`: `setup.sh`, `foo.bar`, version strings adjacent to text.
- No test for phone spanning newline / sentence (`M1`), nor overlap priority (URL containing digits ≥7, host inside URL).
- `ComposeSubjectField` is untestable AppKit; needs manual verification (M3).
- Tests were not executed in this review (sandbox denied `swift test`) — run `swift test` before merge.

## Open questions
1. Is bare-host **autolinking** (vs. isolation only) actually wanted for outgoing mail, given the denylist FP surface? The original Fable item said "isolated + autolinked (forms.gov.il)" — an allowlist of TLDs would satisfy that case safely.
2. Should leading/trailing blank lines really survive into sent HTML (L2)?

## Backlog status
Done: bare-host isolation ✔, phone/ID ≥7-digit isolation (editor + HTML spans) ✔, subject `baseWritingDirection` ✔ (modulo M3 field-editor caveat), markdown per-block `dir` ✔, shared `bareURLRegex` ✔, multi-blank + whitespace-only-blank fidelity ✔.
Remaining true backlog: markdown-body host/phone isolation (L3); TLD allowlist for linkify (H2); email-address guard (H1).

## Verdict
**NOT READY** — H1 (emails mangled into `https://gmail.com` links) and H2 (arbitrary `word.word` autolinked in sent mail) are user-visible regressions in outgoing HTML. Both are small fixes: an `@`/`.` lookbehind on `bareHostRegex` and a TLD allowlist gate in `bareURLMatches`; M1's `\s→[ \t]` is a one-character regex change. With those + tests, this ships.
```
