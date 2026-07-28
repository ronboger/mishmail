---
date: 2026-07-28 14:16
kind: fable-rereview
target: branch fix/snooze-advance-speed vs main
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260728T141446-12477
started_at: 2026-07-28T21:14:46Z
finished_at: 2026-07-28T21:16:20Z
reviewed_commit: 9834f56dd2a236990b94bbd76dc8996e78f2a66f
exit_code: 0
invoked_from: /Users/ronboger/mishmail/.worktrees/snooze-advance-speed
git_branch: fix/snooze-advance-speed
---

# Fable Review Pass 2 — fix/snooze-advance-speed

## Prompt

```
[jacq-claude] Mode: READ-ONLY. Do not modify project files. Analyze and report only.

You are a careful code reviewer. Focus on correctness, security, edge cases, and test gaps. Be specific (file:line).
Compare against git ref 'main' (diff / log as needed).
Focus: Re-review the complete branch diff against main after addressing pass-1 LOW. Check correctness of dismissSnoozePicker only on timed snooze / matching-thread unsnooze, and finish with SHIP or NOT READY.

Deliver:
1. Findings ordered by severity with evidence
2. Open questions
3. Suggested fixes (do not apply unless write mode was requested)

Do not modify files unless explicitly told to write.

```

## Review (verbatim)

id:	review-20260728T141446-12477
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/snooze-advance-speed
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260728T141446-12477/output.log
---
# Re-review: `fix/snooze-advance-speed` vs `main` (pass 2)

## Findings

**No HIGH or MEDIUM findings.** The pass-1 LOW is correctly addressed.

### Focus check: `dismissSnoozePicker` call sites

- **Timed snooze** (`MailStore.swift:4340`): `dismissSnoozePicker()` is called unconditionally, but this is safe. While the sheet is up, the main-window key monitor passes events through (`ContentView.swift:682`) and the sheet is modal, so the only realistic timed-snooze during an open picker is the picker's own `pick` — which is by construction the same thread. The `guard snoozingThread != nil` (`:4316`) makes it a no-op when no picker is up.
- **Unsnooze** (`MailStore.swift:4332`): guarded by `snoozingThread?.id == thread.id`. This correctly protects against `fireDueSnoozes` (`:4368`, loops over due threads on the sync tick) and the Undo closure (`:4353`) yanking a picker open for a *different* row. If the due/undone thread happens to be the one whose picker is open, dismissing it is correct — its "Unsnooze"/footnote state would be stale.
- **`choose()` ordering** (`SnoozeSheet.swift:119-120`): `pick` first (clears the item binding inside a `disablesAnimations` transaction, auto-advance publishes same-update), then `dismiss()` as a harmless no-op fallback — still needed for the schedule-send presenter (`ComposeView.swift:567-575`, `isPresented`-based, `pick` doesn't clear it). Esc (`:139-141`) still cancels via `dismiss()` only, without triggering any snooze. Correct.

### LOW / informational

1. **`leavesInboxList` tightens SENT matching vs main** — `SelectionAdvance.swift:186`: main used substring `t.labelIds.contains("SENT")`; the extracted helper token-matches via `split(separator: " ")`. For real Gmail label sets this is equivalent (arguably more correct), but it is a silent behavior change bundled into a "pure extraction." Worth a one-line note in the commit if you care about diff archaeology. Also note it splits on `" "` while `MessageParsing.hasDraftLabel` (`MessageParsing.swift:405`) splits on `\.isWhitespace`; labelIds are always space-joined (`MessageParsing.swift:42`), so no practical divergence.

2. **Undo-toast wording changed** — old label: `"tomorrow 9 AM"` / `"Aug 12, 9 AM"`; new `SnoozeDateParser.format` yields `"tomorrow 9:00 AM"` / `"Tue Aug 12 9:00 AM"` and adds a `"today …"` case. Intentional per the comment (consistency with picker captions) — cosmetic, fine.

3. **Timed-snooze dismiss lacks the id symmetry of the unsnooze branch** (`MailStore.swift:4340`). Purely defensive nit; unreachable in practice per the modality argument above. Not blocking.

### Tests

- `SelectionAdvanceTests.swift:244-272` covers snooze/archive/stay/showArchived plus the `.remove` + `dropKeepId` plan — good coverage of the actual regression.
- `SnoozeDateParserTests.swift:22-33`: `testUndoLabelUsesSharedFormat` self-references `format(at9)` so it's locale-stable; the `contains("tomorrow")` assertion is wall-clock-relative but `bySettingHour(9, of: tomorrow)` always lands in tomorrow. Robust.
- Untested (acceptable): the `dismissSnoozePicker` id-guard itself — it's `@MainActor` SwiftUI state, no harness exists for it in this repo.

## Open questions

- None blocking. (If a future presenter ever shows `SnoozeSheet` for a non-selected thread while another mutation path can fire, revisit the unconditional dismiss at `:4340`.)

## Suggested fixes (optional, not applied)

- For symmetry, change `:4340` to `if snoozingThread?.id == thread.id || snoozingThread != nil`-style explicit id check — or leave as-is; current code is defensible.

## Verdict

**SHIP.** The pass-1 LOW is fixed correctly, the picker-dismiss guard matches only the intended cases, the extracted `leavesInboxList` faithfully mirrors the `.inbox`/`.account` branch it replaced, and tests cover the regression the branch exists to prevent.

