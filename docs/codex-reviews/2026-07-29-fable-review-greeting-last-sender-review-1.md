---
date: 2026-07-29 15:06
kind: fable-review
target: b543c7a Prefer last-sender From name for greetings; suppress role mailboxes vs b543c7a~1
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260729T150501-85701
reviewed_commit: b543c7a5a7d16e33725850f3f51b7fbe22b51533
invoked_from: /Users/ronboger/mishmail/.worktrees/greeting-last-sender-review
git_branch: detached@b543c7a
---

# Review prompt

Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: Prefer last-sender From display name for greeting Tab autocomplete when To matches the reply target; suppress role/shared mailbox names (Backoffice, Support, noreply, etc.) so we never suggest Hi Backoffice. Reply To only stores bare emails so greeting previously missed the From display of the message being replied to.

# Review: b543c7a — Prefer last-sender From name for greetings; suppress role mailboxes

Reviewed the full diff vs `b543c7a~1` (3 files: `GreetingAutocomplete.swift`, `ComposeView.swift`, tests). Test run was not permitted in this sandbox, so findings are from static review.

## Findings

**Low — potentially undecoded RFC 2047 From names become the greeting**
`ComposeView.swift:1551` feeds `MessageParser.displayName(fromHeader:)` straight into the candidate chain. `displayName` (MessageParsing.swift:241-247) does no encoded-word decoding; if `original.fromHeader` can ever be a raw `=?UTF-8?B?...?=` header, `isUsablePersonName` won't reject it (no `@`, not a role label) and Tab would offer `Hi =?UTF-8?B?...`. If headers are decoded upstream at fetch time, this is a non-issue — worth confirming.

**Low — over-suppression of real people with role-word tokens**
`GreetingAutocomplete.swift:87-90`: *any* token match kills the whole candidate, so "Sue Sales", "Grace Hopper-News", or surname "Bot/Auto/Success" gets no greeting at all — rather than falling back to a usable first name ("Sue"). This is a deliberate design choice per the comment, and failing safe (no ghost) is the right bias; noting it as accepted behavior. Note the test `"Supportive Sue"` passes only because tokenization keeps "supportive" whole — good, that boundary is covered.

**Low — suppressed candidate blocks fallback asymmetrically**
`recipientFirstName` skips a rejected candidate and tries the next (GreetingAutocomplete.swift:131-135), which is correct. But when headerName is "Backoffice" and the *contact* name is a real person ("Priya Ops-Desk" aside), the contact still gets a chance — good. No bug; however there's **no test** for the fallback path "headerName unusable → contactName used" (e.g. `headerName: "Support"`, `contactName: "Priya"` → `"Priya"`). Cheap to add.

**Info — doc comment slightly wrong**
`GreetingAutocomplete.swift:51-52` says "its first token"; the implementation matches *any* token. Comment at :84-86 is accurate; the header comment isn't. Cosmetic.

**Info — `hello` in the label set**
Contact display name "Hello" is suppressed (fine), but note `firstName` candidates like "Hello Kitty Fan Club" also die — consistent with intent.

## Correctness checks that pass

- Email-equality gate (`ComposeView.swift:1549-1550`) correctly restricts headerName to when To is the reply sender; both sides lowercased; `MessageParser.emailAddress` tolerates malformed headers.
- Bare-From case: `displayName` returns the address itself → contains `@` → rejected → falls through to contact/local-part. No regression.
- `headerName` defaults to `nil`, so all other `recipientFirstName` call sites are unaffected; refactor from if-chains to the candidate loop is behavior-preserving for the old two-candidate order.
- Tests cover: role rejection (single & multi-word), header preference over contact, Backoffice suppression via both contact and local-part guess, real-name pass-through including the "Supportive" near-miss.

## Open questions

1. Are Gmail `From` headers RFC-2047-decoded before reaching `original.fromHeader`? (Determines whether the first finding is real.)
2. Intentional that "hr", "ops", "news", "mail" as *surname* tokens suppress the entire name instead of falling back to the first name? (Current behavior: yes, suppress — seems fine.)

## Suggested fixes (not applied)

- Add test: `recipientFirstName(token: "priya@x.com", contactName: "Priya Sharma", headerName: "Support")` → `"Priya"`.
- Fix the "first token" wording in the comment at GreetingAutocomplete.swift:51-52.
- If From headers can be undecoded, reject names containing `=?` in `isUsablePersonName`.

## Verdict

**SHIP** — the change matches the task, is fail-safe (suppression yields no ghost rather than a wrong one), preserves existing call sites, and has solid targeted test coverage. Findings are minor hardening/test-gap items.
