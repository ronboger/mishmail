---
date: 2026-07-29 16:06
kind: review
target: branch fix/compose-short-reply-spacing vs main
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260729T160608-22665
reviewed_commit: f59dd02a9eaa7463e9c149e71e7f9712e84d4222
invoked_from: /Users/ronboger/mishmail/.worktrees/compose-short-reply-spacing
git_branch: fix/compose-short-reply-spacing
focus: pass-2 emptyFloor hold + no first-keystroke snap
---

# Prompt

Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: Fix weird vertical spacing in short reply compose (180pt body floor → content-aware layout). Pass 2 addresses Fable MEDIUM from review-1: emptyFloor now holds until content+slack exceeds it so first keystroke / last delete do not snap the editor; dropped dead nonEmptyFloor; tests pin empty↔one-char stability and slash-without-quote guard order.

# Verbatim review

id:	review-20260729T160608-22665
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/compose-short-reply-spacing
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260729T160608-22665/output.log
---
Reviewed the full diff (2 commits, 4 files) against `main`.

## Findings

**LOW-1 — Whitespace-only multi-line body can overflow the fixed frame.**
`ComposeBodyLayout.swift:66-68`: a body of e.g. eight bare newlines trims to empty → `raw = emptyFloor` (100pt), but the actual editor content is ~8 visual lines (~168pt). Since min==max, the editor becomes a fixed 100pt frame with internal scroll and the caret can sit below the visible area. Old code had the same `contentHeight` path but a 180pt floor masked it more. Cosmetic edge case; nobody writes newline-only drafts on purpose, but a user hammering Enter before typing will see internal scrolling.

**LOW-2 — Character-count wrap heuristic vs. real NSTextView wrapping.**
`ComposeBodyLayout.swift:38-42` estimates wraps at 72 chars, ignoring proportional font width, emoji, and word-wrap boundaries. Because pass-1 made the frame content-hugging (min==max) rather than a loose floor, a mismatch now shows as either a sliver of internal scroll or extra slack near wrap boundaries, and the frame re-resolves every keystroke once past the 100pt floor. Acknowledged in comments; acceptable given the 8pt `contentSlack`, but it's the most likely source of residual jitter reports.

**INFO — Correctness of the pass-2 fix itself: verified.**
- `max(raw, emptyFloor)` at `ComposeBodyLayout.swift:73` makes the empty↔one-char transition continuous (43+floor→100 both sides); the transition at raw≈100 is mathematically continuous, so no snap at the hug threshold either. The dead `nonEmptyFloor` is indeed gone.
- Guard order (`hasCollapsedQuote` before `slashActive`) preserves old behavior exactly — old code's `slashActive && !quotedTail.isEmpty` conditions are equivalent to the new early-return structure. `ComposeView.swift:206-220` is a faithful refactor; no-quote path still returns `(120, .infinity)`.
- Test arithmetic checks out: "A" → 43 < 100 ✓; 3-line short reply → 81 < 100 ✓; 8 lines → 176 > 100 ✓; 40 lines → capped at 320 ✓. `testSlashWithoutCollapsedQuoteIsIgnored` pins the guard-order regression from review-1.
- `project.yml:188` adds the new file to the **MishMailTests** target sources (the app target picks it up via its own source list per the diff hunk at line 185) — tests compile the source directly into the test module, consistent with siblings like `ComposeFooterLayout.swift`, so no `@testable import` is needed. ✓

**Behavior deltas vs main (all intended):** empty reply surface 180→100pt; short replies hug at 100pt instead of 180; drafts between ~100–320pt now resize per keystroke instead of holding 180.

## Open questions
1. I did not execute the test suite (read-only session, xcodebuild run not requested) — arithmetic was verified by hand. Worth one `xcodebuild test -only-testing:MishMailTests/ComposeBodyLayoutTests` before merge.
2. Is LOW-1 (newline-only draft scrolls inside a 100pt frame) worth handling? One-line fix if so.

## Suggested fixes (not applied)
- LOW-1: use `raw = max(emptyFloor, contentHeight(body:) + contentSlack)` unconditionally — i.e., drop the `isBodyEmpty` branch entirely and always take content height; the floor already handles the empty case, and newline-only bodies then size correctly. (This also deletes `isBodyEmpty` unless used elsewhere.)
- LOW-2: no action now; if jitter is reported, measure with `NSAttributedString.boundingRect` instead of char counts.

## Verdict
**SHIP** — pass-2 correctly resolves the review-1 MEDIUM (no first-keystroke/last-delete snap), the refactor is behavior-preserving on all other paths, and tests pin the regressions. The two LOWs are cosmetic edge cases.
