---
date: 2026-08-19 17:08
kind: fable-iterate review
review_model: claude-fable-5
review_effort: low
requested_model: claude-fable-5
resolved_model: claude-fable-5
model_substitution: none
job_id: review-20260819T170458-71639
branch: fix/from-picker-send-identity
base: main (6d5e19e)
reviewed_commit: af93f7c4d6a665a4d242017b526d8617e2f84b02
verdict: SHIP
started_at: 2026-08-20T00:04:58Z
finished_at: 2026-08-20T00:08:59Z
checks: make test → TEST SUCCEEDED, 1637 tests, 5 skipped, 0 failures
---

# Review pass 1 — From picker + send-as mailbox pin

## Prompt

```
Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: (1) Make the compose From picker clearer — every identity showed the same display name (Ron Boger) so the domain was hard to scan. (2) Investigate/fix a bug where changing From to berkeley (especially around /bball snippet send) still sent from ron@ronboger.com.

The implementer diagnosed: new compose pinned apiAccountId to the first autosave draft's mailbox, so a later From change still sent through the original mailbox and Gmail rewrote From to that mailbox's default send-as.
```

## Verbatim review

Permission deny rule "MultiEdit" matches no known tool — check for typos.
# Review: fix/from-picker-send-identity vs main

**Verdict: SHIP.**

The diagnosis is correct. The old `apiAccountId` returned `draftAccountId` before `requested` (`Sources/MishMail/Support/SendIdentity.swift:160` area, pre-change). ComposeView passes `replacingDraft: liveDraft` on send. So the first autosave pinned the send mailbox. A later From pick to berkeley still sent through the original mailbox. Gmail then rewrote From to that mailbox's default send-as. The fix makes `requested` win for new mail. `draftAccountId` is only a fallback when `requested` is empty. Replies still pin to the thread mailbox.

## Findings by severity

**No high or medium findings.** I checked the risky interactions:

- Cross-mailbox draft replacement is safe. `send()` deletes the old draft through the draft's own account (`deleteUnderlyingDraft` uses `draftMessage.accountId`, MailStore.swift:6009). The new mailbox never gets a foreign draft id.
- No 404 regression. `SendThreading.apiThreadId` rejects a foreign composite threadId (SendThreading.swift:32). A send moved to another mailbox starts a new conversation instead of passing the old mailbox's threadId.
- Reply safety holds. `replyAccountId` still wins first, and the picker locks to the thread mailbox via `fixedMailboxAccountId`, so a reply cannot cross mailboxes.
- Fingerprint baseline is re-seeded after prefill (ComposeView.swift:595-605), so adding `fromAccountId` to the fingerprint does not cause a spurious autosave on open.

**Low severity:**

1. `ensureFromSelection` sticky match (ComposeView.swift:1523-1527) matches by email only. If the draft's own mailbox loses that alias, a late identity load can select the same address on a different mailbox. The new fingerprint then dirties, and autosave migrates the draft to that mailbox with no user action. The window is narrow; `preferCurrent` protects exact matches.
2. `fromIdentityBinding` returns tag `""` when no identity matches `fromEmail` (ComposeView.swift:1475). The Picker gets a selection not present in its tags. This is a SwiftUI console warning only; the closed label falls back to `fromEmail` correctly.
3. Cosmetic: `fromClosedLabel` can include "(via mailbox)" in the compact From row, which can be long.

## Test coverage

`SendIdentityTests` cover the resolver fix (`testApiAccountIdHonorsNewComposeFromAfterAutosave` reproduces the /bball scenario), the tautological-via skip, shared-name drop, and sort order. I ran the suite with xcodebuild; all listed tests pass. There is no test for the ComposeView binding or fingerprint change; that is UI-layer and acceptable.

## Open questions

- Should the sticky-email match in `ensureFromSelection` prefer the current `fromAccountId`'s mailbox before other mailboxes? That would close finding 1.

## Suggested fixes (not applied; read-only)

- Finding 1: in the sticky branch, try `options.first(where: email match && accountId == fromAccountId)` before the email-only match.
- Finding 2: add an explicit `Text("").tag("")` hidden row, or guard the Picker behind a non-empty match.
