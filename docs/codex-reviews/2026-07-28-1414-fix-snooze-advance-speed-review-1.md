---
date: 2026-07-28 14:14
kind: fable-review
target: branch fix/snooze-advance-speed vs main
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260728T141155-9839
started_at: 2026-07-28T21:11:55Z
finished_at: 2026-07-28T21:13:54Z
reviewed_commit: 4c93cba7e5aa6b0c8205931e2b54330b23bec7bc
exit_code: 0
invoked_from: /Users/ronboger/mishmail/.worktrees/snooze-advance-speed
git_branch: fix/snooze-advance-speed
---

# Fable Review Pass 1 — fix/snooze-advance-speed

## Prompt

```
[jacq-claude] Mode: READ-ONLY. Do not modify project files. Analyze and report only.

You are a careful code reviewer. Focus on correctness, security, edge cases, and test gaps. Be specific (file:line).
Compare against git ref 'main' (diff / log as needed).
Focus: Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: snoozing feels a bit slow when moving to the next, not like the speed of deletion and archive. Diagnose and fix.

The fix dismisses the snooze picker without animation before the optimistic mutation so auto-advance is visible immediately (like archive/trash), reuses SnoozeDateParser for undo labels instead of DateFormatter, and extracts leavesInboxList for unit tests.

Deliver:
1. Findings ordered by severity with evidence
2. Open questions
3. Suggested fixes (do not apply unless write mode was requested)

Do not modify files unless explicitly told to write.

```

## Review (verbatim)

id:	review-20260728T141155-9839
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/snooze-advance-speed
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260728T141155-9839/output.log
---
Review complete — findings below.

## Findings (by severity)

### LOW — `dismissSnoozePicker()` fires on all snooze paths, including background unsnooze
`MailStore.swift:4329` calls `dismissSnoozePicker()` at the top of `snooze(_:until:)`, *before* the `guard let date else` unsnooze branch. `fireDueSnoozes()` (`MailStore.swift:4363`) runs on the sync tick and calls `snooze(thread, until: nil)` for each due thread — so if the user has the snooze picker open for a *different* thread when any snooze comes due, the sheet silently vanishes (no animation, no explanation). The guard only checks `snoozingThread != nil`, not thread identity. Same applies to the undo closure at `MailStore.swift:4348`, though that's unreachable while the modal sheet is up on macOS; the sync-tick path is real.

**Suggested fix:** move the `dismissSnoozePicker()` call below the unsnooze guard (only the timed-snooze path needs it), or guard on `snoozingThread?.id == thread.id`.

### INFO — SENT check is now token-aware (behavior change, but a fix)
Old inline code was `t.labelIds.contains("SENT")` — a substring match on the space-separated label string. New `leavesInboxList` splits on spaces and matches tokens, consistent with the token-aware SQL in `Database.swift:956-957`. Stricter and more correct; no Gmail system label contains "SENT" as a substring, so practical behavior is unchanged.

### INFO — Undo toast wording changes
Old: `DateFormatter` with `"'tomorrow' h a"` / `"MMM d, h a"`. New `SnoozeDateParser.format` (`SnoozeDateParser.swift:175`) yields `"tomorrow 9:00 AM"`, `"today …"`, or `"Wed Jul 29 …"` — minutes are now shown, and today/weekday forms replace the flat `MMM d`. Cosmetic, intentional (consistency with picker captions), just noting the visible copy change.

## Verified correct
- `labelIds` is a space-separated `String` (`Database.swift:28`) — the extracted `leavesInboxList` signature and the call site in `MailStore.swift:4009-4015` match; refactor is behavior-preserving for the `.inbox`/`.account` branch.
- MailStore imports SwiftUI, so `Transaction`/`withTransaction` compile.
- The sheet is item-driven (`ContentView.swift:311` `.sheet(item: bound.snoozingThread)`), so nil-ing the item inside a `disablesAnimations` transaction is the right dismissal mechanism. The trailing `dismiss()` in `DatePickSheet.choose` is a harmless no-op for snooze and still needed for schedule-send, as the comment says.
- Keyboard events are swallowed while the sheet is up (`ContentView.swift:682`), so no re-entrant keyboard snooze while the picker is open.
- Test coverage is good: leave-list parity with archive, `showArchived` gating, `plan(...).dropKeepId` so `is:unread` keep-ids can't pin the row, neighbor advance, and undo-label format (including the tomorrow wall-clock case).

## Open questions
1. Tests were not executed in this read-only session (Xcode project; would require an xcodebuild test run). Assumed green per branch state — worth confirming before merge.
2. Is silently closing an open picker when a background snooze fires acceptable, or should the LOW fix land first?

## Verdict
**SHIP** — the core fix is correct and matches the archive/trash fast path; the LOW finding is an edge-case UX nit suitable for a small follow-up (move `dismissSnoozePicker()` below the unsnooze guard).

