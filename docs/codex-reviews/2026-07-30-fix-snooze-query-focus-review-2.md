---
date: 2026-07-30 10:43
kind: fable-review
target: branch fix/snooze-query-focus vs main
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260730T104101-97187
started_at: 2026-07-30T17:41:01Z
finished_at: 2026-07-30T17:42:30Z
reviewed_commit: b1d57cc18f9b147b69134bccef291b8677704dc3
exit_code: 0
invoked_from: /Users/ronboger/mishmail/.worktrees/snooze-query-focus
git_branch: fix/snooze-query-focus
---

# Fable Review Pass 2 — fix/snooze-query-focus

## Prompt

```
Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: when user hits b for snooze, focus should go directly into the typing box. Typing letters like 's' must fill the date query (not type-select an email starting with s). Typing 's' should also surface good autosuggestions like sat/saturday, sun/sunday, september.

Pass 2: previous review SHIPed with M1 (function-key private-use glyphs). That was fixed by rejecting U+F700…F8FF in DatePickQueryInput. Confirm M1 is resolved and re-check the full branch diff.
```

## Review (verbatim)

```
id:	review-20260730T104101-97187
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/snooze-query-focus
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260730T104101-97187/output.log
---
Review complete. Branch diff vs merge-base `2093be3` is tightly scoped: `DatePickQueryInput.swift` (new), `SnoozeDateParser.swift`, `SnoozeSheet.swift`, two test files, `project.yml`. (The `git diff main` noise in MailStore/SyncEngine/SidebarCounts is main-side commits after branching, not part of this branch.)

## M1 verification (function-key private-use glyphs)

**Resolved.** `DatePickQueryInput.isNonTypingScalar` (DatePickQueryInput.swift:35-39) rejects `Cc` control chars and U+F700…F8FF, checked per-scalar across the whole `characters` string (so a multi-scalar payload containing one glyph is rejected wholesale, not partially appended). Pinned by `testFunctionKeyPrivateUsePassThrough` and `testControlCharactersPassThrough` (DatePickQueryInputTests.swift:35-58) using realistic payloads (`\u{F702}`/`\u{F703}` with arrow keyCodes). Good.

## Findings by severity

**Low — passThrough outcomes are still swallowed by the monitor.** SnoozeSheet.swift:166-175: inside the `mods.isEmpty && !isEditing` block, `return nil` executes even when `DatePickQueryInput.handle` returns `.passThrough` (tab, unfocused left/right arrows, nil-character keys). The `Outcome.passThrough` doc says "leave it for AppKit / other handlers," but the caller doesn't. The comment ("Always claim bare unmodified keys while unfocused") says this is intentional — and it does correctly guarantee no type-select leakage — but it contradicts the enum's own documentation and means, e.g., Tab can't move focus while the field hasn't won it yet. Cosmetic in practice (focus is being forced anyway); worth aligning the doc comment or honoring passThrough.

**Low — single-letter + hour query yields nothing.** `isDateWord` (SnoozeDateParser.swift:177) still requires `count >= 2` for weekday prefixes, so `"s 10"` produces zero suggestions while `"sa 10"` works. Consistent with the old behavior, and single-letter+hour is an unlikely input; noting for completeness.

**Info — monitor is app-wide while the picker is open.** The local monitor claims ↑/↓/Return/Esc and now bare typing keys without checking `event.window`. Pre-existing pattern (same as before this branch for the nav keys), and the picker is modal-ish, so acceptable — but a second window open during snooze would have its typing eaten unless its first responder is an editable text view.

## Correctness of the three task requirements

1. **`b` → focus in box**: triple-shot focus (immediate + next-runloop + 80ms, SnoozeSheet.swift:104-106) plus the key monitor bridging the race window. Caret parked at end on focus-win (`.onChange(of: fieldFocused)`, :109-119) so routed-in text isn't replaced by select-all. ✓
2. **`s` fills query, not type-select**: unmodified keys claimed while `TextFocus.isEditing` is false; `TextFocus.isEditing` verified present (TextFocus.swift:25). Delete-on-empty still claims (tested), preventing leak-through. ✓
3. **`s` suggestions**: weekday min-length dropped to 1 (Saturday/Sunday), new bare-month path adds September (1st, 8am, next-year rollover). The `wholeMatch(of: /[a-z]+/)` guard correctly keeps `"aug 12"` on the day path. All covered by `testSingleLetterSSuggestsSatSunSeptember`, `testBareMonthSeptember`, `testBareMonthPastRollsToNextYear`, `testSatAndSunWeekdayPrefixes` with a fixed fixture date. ✓ (Cap of 5 holds: "s" produces exactly 3.)

## Open questions

- Is swallowing Tab/F-keys while the field is unfocused deliberate UX, or should passThrough return the event? (Behavior is safe either way.)
- Tests were not executed in this pass (read-only mode; Xcode-project build writes artifacts). The new tests are deterministic (fixed `now` fixture) and locale-dependent only via `Calendar.current` weekday/month symbols — they assume an English locale, same as the pre-existing tests in the file.

## Suggested fixes (optional, not applied)

- Either honor `.passThrough` by `return event` in the monitor's default branch, or update `Outcome.passThrough`'s doc comment to say "not typed into the query (event may still be swallowed by the caller while unfocused)."
- Optionally drop the `s.count >= 2` weekday guard in `isDateWord` to match the new single-letter suggestion behavior.

**Verdict: SHIP** — M1 is resolved with tests; remaining findings are low-severity polish.
```
