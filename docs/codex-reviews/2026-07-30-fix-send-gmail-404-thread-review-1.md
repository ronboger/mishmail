---
date: 2026-07-30 15:15
kind: fable-review
target: branch fix/send-gmail-404-thread vs main
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260730T151337-82703 (jacq-claude auth failed; re-ran equivalent claude -p with same model/effort)
reviewed_commit: 757507e6134f6dbbe0d3b621aded1a6ecfc25aea
invoked_from: /Users/ronboger/mishmail/.worktrees/send-gmail-404-thread
git_branch: fix/send-gmail-404-thread
focus: Fix Gmail API error 404 when sending email (stale/foreign threadId)
---

# Fable Review — send Gmail 404 threadId

**Prompt:** Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: Fix Gmail API error 404 when sending email. Screenshot showed 'Send failed: Gmail API error 404' on compose (and Draft not saved). Root cause: messages.send / drafts.create were given a stale or foreign Gmail threadId. Fix extracts bare thread ids only for the owning account, omits empty ids, retries once without threadId on 404, and uses the new Gmail thread id on draft stand-in after fallback.

## Verbatim review

1) Summary

The diff fixes "Send failed: Gmail API error 404" on send/draft-save. It adds `SendThreading`, a pure helper enum that (a) picks the reply parent's threadId over the draft's, (b) extracts the bare Gmail thread id from the local composite `"<accountEmail>:<gmailThreadId>"` only when the composite is owned by `apiAccountId` (case-insensitive prefix match), rejecting empty/whitespace ids and foreign composites, and (c) detects `GmailError.http(404, _)`. MailStore's send and draft-create paths now use the helper, and both retry exactly once with `threadId: nil` when the first attempt 404s with a non-nil threadId. The draft path tracks `keptExistingThread` so the stand-in Message uses Gmail's newly created thread id after a fallback rather than the dead local one. `GmailClient.send`/`createDraft` defensively omit empty/whitespace threadIds. New unit tests cover the helper; project.yml registers the new file.

2) Findings

MEDIUM — Behavior change for legacy bare draft/reply threadIds is intentional but subtly broad: `apiThreadId` returns `nil` for any value containing `:` that doesn't match the account prefix. If local composite ids ever use an account identifier other than the email (e.g. an internal account UUID vs. `apiAccountId`), threading would silently be dropped on every reply — mail still sends, but as a new conversation with only RFC headers linking it. The old code always split on the last `:`, so a mismatch between the composite prefix format and `apiAccountId` would regress threading silently. Worth confirming composites are always `"<apiAccountId>:..."` (the code comment asserts "always true after resolve", suggesting yes). Not blocking since In-Reply-To/References headers still thread on the recipient side and usually on Gmail's side too.

LOW — The 404 retry in the send path resends the same `raw`. If the first `messages.send` 404s *after* Gmail has accepted the message (essentially impossible for a 404, which fails before creation), no duplicate would occur — fine. But a transient proxy-level 404 would cause a second send; acceptable risk, and scoped to 404 only.

LOW — `apiThreadId` splits on the *first* prefix occurrence via `hasPrefix`/`dropFirst` rather than last-`:`; a bare Gmail thread id containing `:` is impossible, so this is fine, but an email address containing uppercase letters in the stored composite is handled (case-insensitive) — good. Edge case: an account email that is a prefix of another (e.g. `a@x.com` vs `a@x.com.b@y.com`)—not realistic.

LOW — In the send path, if the retry-without-threadId also fails, the original 404 error is lost and the second error is thrown. Reasonable, just noting the diagnostics tradeoff.

3) Test coverage

Good coverage of the pure helper: owning-account extraction, case-insensitive prefix, foreign composite rejection, empty-bare-after-prefix, nil/blank/empty-account inputs, already-bare acceptance, other-composite rejection, reply-over-draft preference, and 404-only detection including non-HTTP errors. Not covered (harder without a network fake): the MailStore retry orchestration itself — the once-only fallback, `keptExistingThread` flipping, and the stand-in Message threadId selection. That logic is where a regression would most likely hide; if a GmailClient test seam exists it would be worth adding, but the logic is simple and readable.

VERDICT: SHIP
