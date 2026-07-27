---
date: 2026-07-27 11:52
kind: review
reviewer: Fable (Claude Code subagent, not a /codex:* command)
target: commit 05bad01 "Add Gmail-style Accept/Decline/Maybe for calendar invites"
verdict: needs-attention → addressed in 0373a58
codex_session_id: n/a
job_id: n/a
duration: n/a
invoked_from: /Users/ronboger/mishmail/.worktrees/calendar-invite-rsvp
git_branch: feat/calendar-invite-rsvp
git_head: 05bad01997979caf1fe7a4b9881870ec68836e0d
diff_size: 6 files, +1040 / −7
focus: >
  iTIP REPLY correctness; identity selection; parser robustness (RECURRENCE-ID,
  VALARM, Windows TZID, quoted CN); Open in Calendar regression; REQUEST-only
  actionability; ATTENDEE-based identity matching.
follow_up_commit: 0373a58a1c9e7b934b981a7f9a9c99aeb1a0c50d
---

# Review of 05bad01 (`feat/calendar-invite-rsvp`)

## Review: 05bad01 — Calendar invite Accept/Decline/Maybe

**Verdict: needs-attention.** The core is solid — the iTIP REPLY is well-formed, threading is correct, identity selection is sensible, escaping/header-injection hygiene is good, and all 13 new tests pass plus the app target builds clean (verified). But there are two real correctness gaps (RECURRENCE-ID, VALARM bleed-through) and one product regression (.ics is now completely inaccessible as a file) that I'd fix before merging.

### Verified good

- **iTIP REPLY shape** (`CalendarInvite.swift`): UID, SEQUENCE echoed from the request, fresh DTSTAMP, ORGANIZER, single ATTENDEE with PARTSTAT, CRLF line endings, `text/calendar; method=REPLY` MIME type. MIMEBuilder preserves the `method=REPLY` parameter (it appends `; name="invite.ics"`, which is fine) — confirmed via `testMIMEBuilderKeepsCalendarMethodParameter` and by reading `MIMEBuilder.build`.
- **Threading**: `rsvpToInvite` passes `replyTo: message`, and `send()` sets In-Reply-To, References, and the Gmail `threadId`, routed through `SendIdentityResolver` so the thread belongs to the sending account. This matches Gmail's own RSVP behavior.
- **Identity selection** (`MailStore.swift`): send-as matching To/Cc, falling back to primary, is reasonable. `fromEmail` only ever comes from `fromIdentities`, so no arbitrary From spoofing.
- **Failure handling**: local RSVP state is stored only after a successful send, and the card re-reads stored state, so a failed send never fakes a highlighted button. Demo mode is gated. `project.yml` is correct.

### Correctness issues (confirmed by reading the code)

1. **RECURRENCE-ID is dropped** — parser never reads it and `replyICS` never emits it. For an invite to a *single instance* of a recurring event (Google sends these with `RECURRENCE-ID`), the REPLY is ambiguous.
2. **VALARM properties bleed into the event** — the prop loop runs until `END:VEVENT` with no handling of nested `BEGIN:VALARM…END:VALARM`. Outlook invites routinely carry a VALARM with its own `DESCRIPTION:REMINDER`.
3. **Dead code that's also a missed feature**: `attendeeLines` is collected and never used. The ATTENDEE list is exactly what `preferredRSVPIdentity` should be matching against.
4. **Windows TZIDs silently fall back to local time** — `TimeZone(identifier: "W. Europe Standard Time")` is nil.
5. **Quoted params with `;` or `:` mis-parse** — `ORGANIZER;CN="Boger; Ron":mailto:…` splits params inside quotes.

### Product / safety

6. **Regression: the .ics file is now unreachable** — filtered out of the chips and the card offers no Open/Quick Look/Save. Since this feature deliberately does *not* write to any calendar, the only way to get the event into Apple Calendar was opening the .ics.
7. **Does the guest's own Google Calendar update?** — Suspected when organizer is on Google Calendar; Exchange/other may leave guest copy as Needs action.
8. **`isActionable` includes `.unknown` and `.publish`** — restrict to `.request`.
9. **Inline `text/calendar` body parts without filename/attachmentId** — known gap; fine to defer.
10. **Multiple VEVENTs**: first-only; fixing #1 covers the common recurring-instance case.

### Tests

Coverage good for happy paths. Missing: TZID (IANA + Windows), RECURRENCE-ID, VALARM skipping, quoted-CN organizer, Method.unknown actionability.

Nothing is a blocker in the "this corrupts data" sense — items 1, 2, 6, and 8 are the ones to address before merge; the rest can be follow-ups.

---

## Follow-up (0373a58)

Addressed pre-merge items:

| # | Fix |
|---|-----|
| 1 | Parse + echo `RECURRENCE-ID` line verbatim in METHOD:REPLY; RSVP persistence keyed per instance |
| 2 | Nested component skip (`BEGIN:VALARM`…`END:VALARM`) so REMINDER never overwrites DESCRIPTION |
| 3 | `attendeeEmails` used first in `preferredRSVPIdentity` |
| 4 | Common Windows→IANA TZ map + quoted-param-aware `splitProperty` |
| 6 | Open in Calendar / Quick Look / Save on card + context menu |
| 8 | `isActionable` is REQUEST-only |

Tests: 848 pass (+10 for the follow-ups).
