---
date: 2026-07-30 17:18
kind: fable-rereview
reviewer: Fable (jacq-claude)
target: fix/calendar-invite-double-card vs main (after key-scope fix)
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260730T171714-51560
reviewed_commit: e63f50c8eea6bc601edfdbe6f32ee7c2feab729f
prior_review: docs/codex-reviews/2026-07-30-fix-calendar-invite-double-card-review-1.md
invoked_from: /Users/ronboger/mishmail/.worktrees/fix-calendar-double-card
git_branch: fix/calendar-invite-double-card
focus: >
  Re-review after key-scoping removeAll and inline skip; mixed-filename test.
---

# Fable Re-review — calendar invite double-card (pass 2)

## Prompt

Re-review after addressing pass-1 findings. Diff is vs main on fix/calendar-invite-double-card.

Pass-1 was SHIP with Medium: removeAll dropped all inline calendars without key match. Fixed: removeAll and inline skip both key-scoped via calendarAttachmentDedupeKey; added testParseMixedInlineAndDownloadableDistinctFilenamesKept.

Confirm the key-scoping fix is correct, no regressions on Google dual-MIME collapse, and finish with SHIP or NOT READY.

## Verbatim review

```
id:	review-20260730T171714-51560
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/fix-calendar-double-card
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260730T171714-51560/output.log
---
Re-review complete. The key-scoping fix is verified — evidence below.

## Findings

**Confirmed fixed — pass-1 Medium (key-scoped `removeAll` + inline skip)**
- `Sources/MishMail/Gmail/MessageParsing.swift:129-135` — `removeAll` now requires `calendarAttachmentDedupeKey(filename:) == key` in addition to the inline-sentinel + calendar checks. An inline `standup.ics` no longer gets dropped when a downloadable `retro.ics` arrives later.
- `MessageParsing.swift:175-184` — the inline-branch guard (pass-1 Low #2) was tightened symmetrically to the same key comparison, so downloadable-first + inline-second with distinct names also keeps both. Both walk orders are now consistent.
- Covered by `Tests/MishMailTests/MessageParsingTests.swift:602` (`testParseMixedInlineAndDownloadableDistinctFilenamesKept`), which asserts both rows survive, standup stays the inline sentinel, and retro keeps `att-retro`.

**No regressions on the Google dual-MIME collapse** — I traced all four orderings:
1. Inline first, downloadable second (real Google shape): inline row appended (`already` false), then `removeAll` deletes it by key, `already` false → downloadable appended. One row, `att-invite` wins. Test: `testParseGoogleCalendarInviteDoesNotDoubleCard`.
2. Downloadable first, inline second: inline `already` matches by key → skipped. One row.
3. Both attachmentIds: `removeAll` no-ops (neither is inline sentinel), `already` true → first wins. Test: `testParseGoogleCalendarBothAttachmentIdsDoesNotDoubleCard`.
4. Two inline same-key parts: second skipped by inline `already`. One row.
Empty/unnamed inline → `invite.ics` synthetic name still collides with the named attachment via `calendarAttachmentDedupeKey` (`CalendarInvite.swift:139-145`), test-verified.

**Low (informational, pre-existing) — `safeFilename` asymmetry between branches**
The inline branch normalizes via `safeFilename` (`MessageParsing.swift:177`); the attachmentId branch uses the raw part filename (`:115-116`), and `calendarAttachmentDedupeKey` doesn't strip path components. A pathological attachment filename like `x/invite.ics` paired with an unnamed inline part would key-mismatch and double-card. Never observed from Gmail (filenames don't carry paths in practice), pre-dates this branch, and the UI-layer `uniqueCalendarAttachments` would also miss it for the same reason. Not a blocker.

**Low (carried from pass 1, unchanged by design)** — when both duplicates have attachmentIds, first wins, so the persisted mimeType may be `text/calendar; method=REQUEST` rather than `application/ics`. Functionally equivalent (both resolve via `getAttachment`); documented by the both-ids test.

## Open questions
1. A *named non-invite.ics* alternative (`meeting.ics`) + `invite.ics` attachment would still double-card — same open question as pass 1; ignore until observed in the wild.
2. Tests not executed (read-only session); assertions match the traced code paths.

## Suggested fixes (optional, not applied)
- Apply `safeFilename` to `name` in the attachmentId branch (or `lastPathComponent` inside `calendarAttachmentDedupeKey`) to close the asymmetry in one place.

## Verdict

**SHIP** — the pass-1 Medium is correctly fixed with matching key-scoping on both the `removeAll` and inline-skip paths, the new mixed-filename test pins the invariant, and all Google dual-MIME orderings still collapse to one card with the downloadable row preferred.
```
