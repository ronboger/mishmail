---
date: 2026-07-31 15:37
kind: review
target: branch fix/hebrew-english-bidi vs main
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260731T153541-82157
reviewed_commit: 57c63d2ea06104e0d3cb0aed97707036db29c304
invoked_from: /Users/ronboger/mishmail/.worktrees/hebrew-english-bidi
git_branch: fix/hebrew-english-bidi
git_head: 57c63d2ea06104e0d3cb0aed97707036db29c304
---

# Codex / Fable Review (pass 1)

## Prompt

```
[jacq-claude] Mode: READ-ONLY. Do not modify project files. Analyze and report only.

You are a careful code reviewer. Focus on correctness, security, edge cases, and test gaps. Be specific (file:line).
Compare against git ref 'main' (diff / log as needed).
Focus: Review the complete diff against the requested task: fix Hebrew/English BiDi multilanguage support (shredded URLs in mixed RTL+LTR compose, missing dir on authored HTML, no URL isolation).

Check correctness, regressions, and test coverage. Specifically evaluate:
1. TextDirection first-strong detection correctness for Hebrew/Arabic/Latin
2. authoredHeadHTML dir wrapper + link dir=ltr isolation
3. ComposeBodyEditor applyBidiAttributes (paragraph styles + writingDirection embeddings) — does highlight wipe them? does it pollute the model string?
4. Gaps: bare hostnames without scheme, numbers/dates next to Hebrew, subject field, reading pane
5. Test coverage quality

Give findings by severity and finish with SHIP or NOT READY. Also improve the plan: what should be in a follow-up vs must-fix now.

Deliver:
1. Findings ordered by severity with evidence
2. Open questions
3. Suggested fixes (do not apply unless write mode was requested)

Do not modify files unless explicitly told to write.
```

## Verbatim result

```
I've reviewed the full diff vs `main`. Here's the report.

# Code Review: Hebrew/English BiDi fix

## Findings by severity

### Medium

**M1. Paragraph style applied to content range excludes the paragraph terminator — `ComposeBodyEditor.swift:418-431`**
`applyBidiAttributes` sets `.paragraphStyle` over `NSRange(paraStart, contentsEnd - paraStart)`, excluding the trailing `\n`. Cocoa's attribute fixing (`fixAttributes`) requires a uniform paragraph style across an entire paragraph *including its terminator*; when it isn't uniform, AppKit normalizes by propagating the style at the paragraph start — usually benign here, but it does churn attributes every keystroke and can produce flicker/undo noise. Use `paraEnd` (the range including the terminator) instead of `contentsEnd`. Low risk, easy fix.

**M2. Single `dir` for the whole authored body — `MessageParsing.swift:628-634`**
`authoredHeadHTML` picks one direction from the *first strong char of the entire text*. A message starting with one English line ("Hi Yaniv,") followed by Hebrew paragraphs renders the Hebrew paragraphs LTR-based for recipients — the exact class of bug being fixed, just with the languages swapped. Gmail wraps *each paragraph* in its own `dir`. Acceptable for now, but this is the most likely user-visible residual bug. Recommend per-paragraph `dir` (split on blank lines / `\n`) as a fast follow-up, or must-fix if mixed-language mails are the common case for this user.

**M3. Embedding, not isolation, in the compose editor — `ComposeBodyEditor.swift:437-446`**
`NSWritingDirectionFormatType.embedding` (LRE semantics) still lets the URL's direction leak into surrounding neutral characters between the URL and following Hebrew (e.g. a `-` or `:` after the URL can jump sides). `.override` isn't right either; true FSI/isolate has no attribute equivalent, so embedding is the best available AppKit option — but the HTML side uses `dir="ltr"` (isolate semantics in modern engines) so compose preview and sent mail can differ slightly around neutral punctuation. Document this; not fixable cleanly without inserting control chars (correctly avoided since it would pollute the model string).

### Low

**L1. Trailing-punctuation trim is greedier than ComposeLinks — `TextDirection.swift:59-66`**
The loop strips *all* trailing punctuation (`.../x.).` → strips 3 chars), while ComposeLinks tests show single-char trimming (`.../x.` → one). For `https://example.com/x.).` the isolate range and the anchor label can disagree by a char or two. Cosmetic — the mismatch only shifts where isolation ends — but the comment claims "matching ComposeLinks bare-URL trimming," which isn't strictly true. Worth aligning or softening the comment.

**L2. `isStrongLTR` treats Greek/Cyrillic/Latin only; CJK, Hangul, Devanagari, etc. are classified neutral — `TextDirection.swift:93-107`**
"שלום 日本語" → RTL (correct), but "日本語 שלום" → RTL too (should be LTR under real first-strong rules; UAX#9 classifies CJK as strong L). Edge case for this user base; fine as a known limitation, add a comment.

**L3. Subject field gets alignment but no base direction — `ComposeView.swift:899-904`**
`.multilineTextAlignment(.trailing)` right-aligns Hebrew but the field's base direction stays LTR, so a Hebrew subject ending in "!" or containing a Latin word can still display misordered *within* the line. NSTextField needs `baseWritingDirection` (would require an NSViewRepresentable or `.environment(\.layoutDirection, ...)`). Also: no `dir` is emitted for the subject on send — that's fine (headers can't carry it; recipient clients apply first-strong themselves).

**L4. Regex compiled per call — `TextDirection.swift:47-49`**
`ltrIsolateNSRanges` builds the `NSRegularExpression` on every keystroke (called from the highlighter). Cache it in a `static let`. Same pattern exists twice (here and `Markdown.swift:469`) — extract one shared constant so they can't drift.

### Notes / verified-correct

- **Highlight wipe**: `setAttributes` at `ComposeBodyEditor.swift:308-313` does wipe BiDi attrs, but `applyBidiAttributes` runs immediately after, and all subsequent highlight passes use `addAttributes` (colors only) — so paragraph styles and writingDirection embeddings survive. ✔
- **Model purity**: attributes only; `textView.string` never gains FSI/PDI/LRM chars, so drafts and sent bodies stay clean. ✔
- **`ltrEmbed` value**: `.leftToRight.rawValue | .embedding.rawValue` = 0, array-wrapped — matches the documented `NSWritingDirectionAttributeName` encoding. ✔
- **Paragraph loop termination**: verified the `paraEnd <= paraStart → break` guard handles empty-tail and trailing-newline cases. ✔
- **First-strong detection**: Hebrew/Arabic ranges are correct and comprehensive (incl. presentation forms); digits correctly weak; `htmlDir` neutral→ltr matches Gmail convention. ✔
- **Reading pane** `a { unicode-bidi: isolate }`: correct and minimal; anchors default to `unicode-bidi: normal`, so this is a real fix, and it covers received mail too. ✔
- **Markdown path**: both `[text](url)` and bare-URL autolinks now get `dir="ltr"`; wrapped in the outer `dir` div — consistent with the plain path. ✔

## Gaps (acknowledged, mostly follow-up)

1. **Bare hostnames without scheme** (`forms.gov.il`) — not isolated in compose and not autolinked as bare text; only linked via markdown syntax. In Hebrew prose these shred exactly like full URLs. Follow-up: extend the isolate regex with a conservative bare-host pattern reusing ComposeLinks' host validation.
2. **Numbers/IDs next to Hebrew** ("מספר בקשה 2028606") — weak digits are handled by UBA fine in most cases, but phone numbers with `+`/`-` still shred RTL. No isolation for these. Follow-up.
3. **Quoted-reply block** — `authoredHeadHTML` covers only the authored head; if the quote wrapper has its own `dir`, unchanged (didn't verify — open question below).
4. **No test** exercises `applyBidiAttributes` (AppKit-bound). The paragraph-iteration logic could be extracted into a testable pure function returning `[(NSRange, TextDirection)]`.

## Open questions

- Does the quoted-history HTML (`ComposeQuote` wrapper around the original message) preserve/emit `dir` for RTL originals, or does the new outer div only wrap the head?
- Is the compose highlighter re-run on paste of large bodies? Per-keystroke regex compile (L4) + full-storage paragraph walk is O(n) per keystroke — fine for email sizes, but confirm no perf cliff on huge pastes.

## Suggested fixes (not applied — read-only)

- **Now (before merge)**: M1 (use `paraEnd` for the style range), L4 (cache regex).
- **Fast follow-up**: M2 (per-paragraph `dir` in `authoredHeadHTML`), L3 (subject base writing direction), gap 1 (bare hostnames).
- **Backlog**: L1 comment/trim alignment, L2 CJK strong-L, testable extraction of paragraph iteration, phone-number isolation.

## Verdict

**SHIP** — with M1 and L4 as pre-merge nits. The core fixes (first-strong detection, HTML `dir` wrapper, anchor `dir=ltr`, reading-pane isolate CSS, attribute-only compose BiDi) are correct, conservatively scoped, and well-tested where testable. M2 is the one residual user-visible case (English-first mixed mail) and should land as an immediate follow-up.
```
