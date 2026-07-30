---
date: 2026-07-30 10:40
kind: fable-review
target: branch fix/snooze-query-focus vs main
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260730T103702-94764
started_at: 2026-07-30T17:37:02Z
finished_at: 2026-07-30T17:39:00Z
reviewed_commit: 532cad00dc83d03232f87fc2ad50dcdcc7ea25e2
exit_code: 0
invoked_from: /Users/ronboger/mishmail/.worktrees/snooze-query-focus
git_branch: fix/snooze-query-focus
---

# Fable Review Pass 1 — fix/snooze-query-focus

## Prompt

```
Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: when user hits b for snooze, focus should go directly into the typing box. Typing letters like 's' must fill the date query (not type-select an email starting with s). Typing 's' should also surface good autosuggestions like sat/saturday, sun/sunday, september.
```

## Review (verbatim)

```
id:	review-20260730T103702-94764
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/snooze-query-focus
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260730T103702-94764/output.log
---
## Review: `fix/snooze-query-focus` (532cad0 vs main)

### Findings

**M1 — Function/navigation keys append invisible garbage to the query while the field is unfocused**
`DatePickQueryInput.handle` (Sources/MishMail/Support/DatePickQueryInput.swift:25-30) only filters `CharacterSet.controlCharacters` (Unicode Cc). But left/right arrows, Home/End, PgUp/PgDn, and F-keys deliver private-use-area characters (U+F702, U+F729, …) in `charactersIgnoringModifiers` — those are category Co, **not** Cc, so they hit `.consume(query + characters)`. Up/down/Return/Esc are caught earlier in the switch (SnoozeSheet.swift:148-159), but a left/right arrow or Home pressed during the unfocused window silently appends an invisible char, breaking all subsequent suggestion matching with no visual cue (user sees "No date matches" while the query looks fine).

The test `testNilOrEmptyCharactersPassThrough` (DatePickQueryInputTests.swift:44-53) encodes an unrealistic event: real keyCode-123 events carry `"\u{F702}"`, not `nil`/`""` — so the test passes while the real event misbehaves.

Fix: also reject scalars in `0xF700...0xF8FF` (or, more robustly, allow only scalars where `CharacterSet.alphanumerics ∪ punctuation ∪ whitespace ∪ symbols` contains them), and update the test to use `"\u{F702}"`.

**L1 — Caret-parking `onChange(of: fieldFocused)` may never fire in the exact race it targets**
SnoozeSheet.swift:104-119: `fieldFocused` is set `true` in `onAppear` and re-asserted twice. If SwiftUI keeps the binding `true` while actual first-responder attachment lags (rather than resetting it to `false` on a failed request — behavior varies by OS version), `onChange` never fires after the monitor has routed characters in, and the field's select-all will let the next keystroke wipe the routed text (`"s"` → user types `a` → query becomes `a`, not `sa`). The comment says LabelPicker does the same, so there's precedent, but it's worth a quick manual check: press `b`, type `sa` fast, confirm query shows `sa`.

**L2 — Caret parking grabs the window's shared field editor without verifying it belongs to this TextField**
SnoozeSheet.swift:115: `NSApp.keyWindow?.fieldEditor(false, for: nil)` returns whatever field editor the key window has; if focus moved elsewhere between the `onChange` and the async hop, you'd move the caret of an unrelated field. Low likelihood inside this overlay (only one editable field), but a `editor.delegate`/string sanity check would harden it.

**Nit** — `DatePickQueryInputTests` has no case for space (`"next week"` typing path) or multi-scalar input (emoji, dead-key composed chars — dead keys deliver `characters == ""` which correctly passes through, but that's only accidentally covered by the empty-string test).

### What checks out ✓

- Parser change delivers the ask: `"s"` → Sunday, Saturday (weekday prefix loop, SnoozeDateParser.swift:85-88) + September (new bare-month branch, :134-141) = 3 results, under the 5 cap. Worst case `"t"` yields exactly 5 (today/tonight/tomorrow/Tuesday/Thursday) — cap holds, months can't be starved for any letter that also matches 5+ earlier entries (no month starts with t).
- Bare-month branch correctly excluded from `"aug 12"`-style input (space/digits fail `/[a-z]+/`), rolls past months to next year, respects appended times ("sep 3pm" → Sept 1, 3pm).
- Monitor consume path can't double-type: when the field *is* first responder, `TextFocus.isEditing` is true → event passes to the field; when not, monitor consumes and returns nil.
- Cmd/Opt/Ctrl shortcuts still pass through (mods check, SnoozeSheet.swift:161).
- Delete-on-empty claiming is deliberate and tested — prevents fall-through to type-select.
- `project.yml` updated for the new file; parser tests use a fixed fixture date (deterministic).

### Open questions
1. Has the `b` → fast-type `sa` race (L1) been verified manually on the target macOS version?
2. Should the schedule-send sheet flavor also get the routing? It does (shared `DatePickSheet`) — intended, presumably harmless, but it changes behavior for a surface the task didn't mention.

### Suggested fixes (not applied — read-only)
1. In `DatePickQueryInput.handle`, extend the guard: `!characters.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || (0xF700...0xF8FF).contains($0.value) }`, and fix the arrow-key test to pass `"\u{F702}"`.
2. Optionally verify field-editor ownership before parking the caret.

### Verdict

**SHIP** — the core feature (focus claim, s-prefix weekdays + months) is correct and well-tested; M1 is a real but low-impact edge (brief unfocused window + navigation key) that deserves a fast-follow fix.
```
