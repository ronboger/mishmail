---
date: 2026-07-28 12:40
kind: fable-review
target: feat/greeting-tab-autocomplete vs main
verdict: NOT READY
model: claude-fable-5
effort: low
job_id: review-20260728T124052-44403
reviewed_commit: 243e1e26902cd03df06916cde0b344ebb9ac90f7
invoked_from: /Users/ronboger/mishmail/.worktrees/greeting-tab-autocomplete
git_branch: feat/greeting-tab-autocomplete
---

# Review prompt

Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: Gmail-style tab autocomplete for the beginning of threads — Hi/Hey {first name} with greyed-out ghost text visual cue, Tab to accept.

# Review: Gmail-style greeting Tab autocomplete (`243e1e2` vs `main`)

## Findings

### Medium — Ghost/Tab stays live while the caret is inside the quoted tail

`greetingSuggestion` (ComposeView.swift:1472-1479) passes the raw `bodyCaretUTF16` against the *head-only* string, and `GreetingAutocomplete.suggestion` then clamps it: `let caret = max(0, min(caretUTF16, ns.length))` followed by `caret == ns.length` (GreetingAutocomplete.swift:49-53). So in a reply with an empty authored head, a caret sitting anywhere inside the quoted `On … wrote:` block clamps down to `head.length` and passes the "caret at end of head" gate.

Consequences:
- The grey ghost is drawn at the *actual* caret position (drawGhostText uses `selectedRange()`, ComposeBodyEditor.swift:447), i.e. mid-quote — "Hi Alice, " rendered inside the quoted text.
- Tab while editing the quote is hijacked: `acceptGreetingSuggestion()` prepends the greeting to the head and teleports the caret to position 10 (ComposeView.swift:1487-1495), losing the user's editing position.

The codebase already knows about this trap — `slashToken` explicitly guards `bodyCaretUTF16 <= headUTF16` with the comment "clamping would falsely keep a head token live" (ComposeView.swift:1444-1449). The new code repeats the mistake that comment warns against.

**Fix:** in `greetingSuggestion`, guard `bodyCaretUTF16 <= (head as NSString).length` before calling `suggestion(...)` (or drop the clamp in `suggestion` and require exact equality of the un-clamped caret).

### Low — Case-folding can shift UTF-16 offsets in the ghost split

GreetingAutocomplete.swift:60-71: prefix matching is done on `lowercased()` strings, but the ghost is sliced with `fullNS.substring(from: typedLen)` where `typedLen` is the UTF-16 length of the *typed* text. For names where lowercasing changes UTF-16 length (e.g. `İ` → `i̇`, 1 → 2 units), the ghost offset misaligns and could in theory split a character. Exotic, but the split-by-lowercased-compare / slice-by-raw-length mismatch is latent.

### Low — Empty-body ghost baseline is guessed, not measured

ComposeBodyEditor.swift:459-464: when `string` is empty the draw point is pinned to `origin + lineFragmentPadding` with a hand-rolled vertical centering (lines 496-501). With `ensureLayout` already called, the layout manager's `extraLineFragmentRect` exists even for an empty text view; the empty branch ignores it for X/Y and the centering math (`(lineH - size.height) / 2`) assumes the drawn string's box matches the caret line — likely close, but a font/line-height mismatch will show the ghost a pixel or two off vs. subsequently typed text. Cosmetic; needs a visual check.

### Low — Trailing-space glyph width

ComposeBodyEditor.swift:472-480: for the caret-after-last-glyph case, X = `location(forGlyphAt: lastChar) + boundingRect(width)`. For a trailing space (`"Hi "` typed), `boundingRect` may report zero/near-zero width rather than the advance, drawing the ghost slightly overlapping. `lm.location(forGlyphAt:)` on the *extra* glyph index, or `firstRect(forCharacterRange:)`, is the robust way to get the caret X. Cosmetic.

### Info — Scope choices that look intentional and fine

- Tab handler correctly runs only with no modifiers and yields to the slash picker (ComposeView.swift:1552-1555); ⌘-Return, Shift-Tab pass through.
- `hasContent`/draft-dirty logic is untouched — ghost text never enters `body_` until Tab, so no phantom drafts.
- Contact-name preference over bare address (ComposeView.swift:1455-1470) and `person(from:)` reuse look right.
- Reply case (empty head + quoted tail) is handled by `applying` and covered by `testApplyingReplacesHeadKeepsTail`.

## Test gaps

1. **No test for the Medium bug**: `suggestion(authoredBody: "", caretUTF16: 5, firstName: "Alice")` (caret beyond head, as happens mid-quote) currently returns a suggestion — a test asserting nil here would have caught it. Note the existing gating tests only exercise caret *within* the head.
2. No test for `applying` with a clamped/over-length `authoredHeadEndUTF16`.
3. No test for a first name containing non-ASCII/case-folding-sensitive characters.
4. The AppKit drawing path is untestable by design (fine), but nothing exercises the ComposeView glue (`greetingRecipientFirstName` with `toDraft` vs `toTokens`) — acknowledged as view-private, just noting.

## Open questions

1. Should the ghost appear for **replies** at all? The task says "beginning of threads"; the current code shows it in replies too (empty head + quote). Gmail does the same, so probably desirable — but confirm it's intended, since it widens the surface hit by the Medium bug.
2. When the To field holds the user's **own** address (self-note), suggesting "Hi Ron, " is slightly odd — worth gating on `ownEmailAddresses` (already used at 8687f72)?

## Suggested fixes (not applied — read-only)

1. In `greetingSuggestion` (ComposeView.swift:~1475), add before calling `suggestion(...)`:
   `guard bodyCaretUTF16 <= (head as NSString).length else { return nil }`
   and in `GreetingAutocomplete.suggestion` replace the clamp with `guard caretUTF16 == ns.length else { return nil }` so the pure function is honest too. Add the caret-past-head unit test.
2. Optionally compute the ghost slice via the matched template's own prefix length under case folding (or restrict matching to `rangeOfComposedCharacterSequences`-safe compare) to close the case-folding offset edge.

## Verdict

**NOT READY** — one targeted correctness fix needed: the caret-clamp lets the ghost/Tab hijack activate while the caret is inside the quoted reply text (contradicting the codebase's own documented invariant at ComposeView.swift:1444-1446). It's a small, well-understood fix plus one unit test; everything else is cosmetic or optional. After that: SHIP.
