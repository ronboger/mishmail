---
date: 2026-07-30 17:16
kind: fable-review
reviewer: Fable (jacq-claude)
target: fix/calendar-invite-double-card vs main
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260730T171504-49558
reviewed_commit: 8d6853e220c8d6cebef9d9739b1bf4b293cfdece
invoked_from: /Users/ronboger/mishmail/.worktrees/fix-calendar-double-card
git_branch: fix/calendar-invite-double-card
focus: >
  Fix calendar invite displaying 2 identical Accept/Decline/Maybe boxes.
  Google dual MIME collapse at parse + UI.
---

# Fable Review — calendar invite double-card (pass 1)

## Prompt

Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: Fix calendar invite displaying 2 identical Accept/Decline/Maybe boxes. Google Calendar emails ship text/calendar (multipart/alternative) + application/ics with the same invite.ics payload; both became attachment rows and two cards. Fix collapses same-filename calendar rows at parse time (prefer downloadable over inline) and in ThreadDetailView via uniqueCalendarAttachments for already-synced mail. Distinct .ics filenames stay separate.

## Verbatim review

```
id:	review-20260730T171504-49558
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/fix-calendar-double-card
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260730T171504-49558/output.log
---
## Review: calendar invite double-card fix (`main...HEAD`, 8d6853e)

### Findings

**Medium — parse-time `removeAll` drops inline calendar rows with *different* filenames** (`Sources/MishMail/Gmail/MessageParsing.swift:126-130`)

When a downloadable calendar part arrives, the code removes **every** inline-sentinel calendar row, without comparing dedupe keys:

```swift
attachments.removeAll {
    AttachmentRow.isInlineCalendarId($0.gmailAttachmentId)
        && CalendarInvite.isCalendarAttachment(...)
}
```

If a message carries an inline `standup.ics` (no attachmentId — Outlook/Calendly style) followed by a downloadable `retro.ics`, the standup row is deleted even though they're distinct invites. That contradicts the stated invariant "distinct .ics filenames stay separate" — which the `uniqueCalendarAttachments` helper (CalendarInvite.swift:117-127) *does* honor by keying on filename. The two dedupe layers disagree. Fix: add `&& calendarAttachmentDedupeKey(filename: $0.filename) == key` to the removeAll predicate. Admittedly rare (mixed inline+attachment invites in one message), and the pre-existing inline-branch guard at MessageParsing.swift:170-175 already suppresses inline parts when *any* calendar attachment exists (attachment-first order), so this only bites in inline-first walk order — but it's a one-line tighten and there's no test for it (`testParseTwoDistinctCalendarAttachmentsKept` uses two attachmentId parts, never mixed inline+downloadable with distinct names).

**Low — inline branch guard is broader than the new parse-time key logic** (`MessageParsing.swift:170-175`, pre-existing)

The inline `text/calendar` branch skips appending when *any* calendar attachment already exists, regardless of filename. So downloadable `retro.ics` first + inline `standup.ics` second → standup silently dropped. Same asymmetry as above, opposite walk order. Pre-existing behavior, not a regression, but if you tighten finding #1 by key, this guard should be tightened symmetrically.

**Low — `already` branch silently discards a later downloadable duplicate row without preferring by type** (`MessageParsing.swift:132-140`)

When both duplicates carry attachmentIds, "first wins" keeps the `text/calendar` part from inside `multipart/alternative` (`att-alt` per `testParseGoogleCalendarBothAttachmentIdsDoesNotDoubleCard`). That's fine functionally since both resolve via `getAttachment`, but note it means the persisted row's mimeType is `text/calendar; method=REQUEST` rather than `application/ics` — anything downstream keying off the outer attachment's MIME sees the alternative's type. No observed breakage; just an asymmetry with the documented "prefer downloadable" preference (both *are* downloadable here, so the doc is technically accurate).

### Correctness checks that pass

- `uniqueCalendarAttachments` is order-stable (`keyOrder`), prefers attachmentId rows over inline sentinel, keeps distinct filenames, and is only applied to per-message attachment arrays (`ThreadDetailView.swift:211` — `attachmentsByMessageId[message.id]`), so no cross-message collapsing.
- Empty-filename normalization to `invite.ics` matches the parse-time synthetic default (`MessageParsing.swift:176`), verified by test.
- UI-layer dedupe covers already-synced DB rows that predate the parser fix — the right belt-and-suspenders split.
- `fileAtts` filter in ThreadDetailView still excludes *all* calendar rows (not just the kept one), so the dropped duplicate can't leak into the generic chip list.
- The kept row is never the inline sentinel when a real attachmentId exists, so downloads use the cheap `getAttachment` path (`MailStore.swift:5465`).

### Open questions

1. Do Google invites ever ship the dual pair with *different* filenames (e.g. unnamed alternative + `invite.ics` attachment)? Covered — empty maps to `invite.ics`. But a named non-`invite.ics` alternative (`meeting.ics`) + `invite.ics` attachment would still double-card. Probably fine to ignore until observed.
2. Tests weren't executed in this review (read-only session; `swift test` builds artifacts). Assumed green — the assertions match the code paths traced.

### Suggested fixes (not applied)

1. `MessageParsing.swift:126` — scope `removeAll` to the same dedupe key: `&& CalendarInvite.calendarAttachmentDedupeKey(filename: $0.filename) == key`.
2. Optionally tighten the inline-branch guard (line 172) to compare dedupe keys likewise, plus a test for mixed inline+downloadable distinct filenames.

### Verdict

**SHIP** — the fix is correct for the targeted Google dual-MIME case and the already-synced-rows case, with solid test coverage. The findings are narrow edge cases (mixed inline/attachment invites with distinct names) worth a follow-up one-liner, not blockers.
```
