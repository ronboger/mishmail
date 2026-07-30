---
date: 2026-07-30 10:32
kind: review
reviewer: Fable (Claude Code subagent via jacq-claude)
target: branch fix/snooze-unread-badge vs main
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260730T103207-91444
git_branch: fix/snooze-unread-badge
git_head: 7438d82
focus: >
  Fix inbox unread badge counting actively snoozed threads; Gmail-style
  clear snooze when a new message arrives.
---

# Review prompt

Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: Fix inbox unread badge counting actively snoozed threads (list uses notSnoozed; badge did not). Also Gmail-style clear snooze when a new message arrives on a sleeping thread.

# Verbatim Fable review

```
id:	review-20260730T103207-91444
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/snooze-unread-badge
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260730T103207-91444/output.log
---
# Code Review: fix/snooze-unread-badge vs main

I reviewed the full diff (5 files, +148/−24). I could not run the test suite (Bash approval denied in this read-only session), so test results are unverified by me.

## Findings

### Medium

**M1. Prune/backfill can falsely wake a snooze (`SyncEngine.swift:833-838`)**
`preservedSnoozeUntil` clears snooze when `messageCount > existing.messageCount`. Message rows are window-pruned (`pruneMessages` is a documented path into `deriveThreads`, per the comment at SyncEngine.swift:744-747). Sequence: snooze → prune drops old messages → re-derive stores the *lower* messageCount → later backfill/search re-fetches those same old messages → count rises back above stored count → snooze cleared with no genuinely new mail. The `newestDate > lastDate` half is safe (both come from the DB with the same truncation), but the count half compares against whatever the last derive happened to see, not a stable notion of "thread grew."

**M2. Your own drafts and sent replies wake the snooze (`SyncEngine.swift:753-758`, `802-807`)**
`deriveThreads` fetches *all* messages for the thread, including DRAFT and SENT. Saving a draft on a snoozed thread inserts a message row (count+1, newer date) → snooze cleared. Gmail does not wake a snoozed thread when you save a draft or send from it; only an incoming message does. The `testNewMessageClearsSnooze` test only exercises an incoming reply, so this behavior is untested and likely unintended. Fix direction: ignore messages whose labels are DRAFT-only (and arguably SENT-from-self) when deciding wake, or compare against a count of non-draft messages.

### Low

**L1. `fetch` promo/social counts vs `memberships` snoozed asymmetry — none found; they match.** (Checked: `memberships` gate at SidebarCounts.swift:47-48 mirrors the SQL at :126-135; `snoozed` membership `inTrash` gate matches SQL at :143.)

**L2. Wake-at-expiry badge staleness (`MailStore.swift:4595-4604`)**
Badge SQL binds `now` at fetch time; the sleeping thread only re-enters the badge when something triggers a recount. `fireDueSnoozes` runs on the sync tick, so worst case the badge lags one tick after wake time. Pre-existing pattern (the `snoozed` count already binds `now`), acceptable — noting only for awareness.

**L3. `currentUnreadInboxIds` (MailStore.swift:3421-3436) now excludes snoozed but still omits `hideSQL`** — Updates/Forums hidden from the primary badge can still seed the notification baseline. Pre-existing inconsistency, not introduced here; out of scope but worth a follow-up if badge/notification parity is the goal.

### Correctness confirmations
- SQL fragment binding is correct: `notActivelySnoozedSQL` contributes exactly one `?`, and every call site passes `arguments: [now]`, including the divergent `badgeAccount` branch (SidebarCounts.swift:155-158). Account-scoped `count` prepends `accountId` before the fragment args in the right order (:184).
- `snoozeUntil <= now` matches the list's `notSnoozed` predicate exactly (MailStore.swift:2564) — boundary semantics consistent.
- Date-precision false-wake is not an issue: both `newest.date` and `existing.lastDate` originate from stored DB rows, so truncation is symmetric.
- Test coverage for the stated task is solid: badge exclusion (SQL + memberships + past-wake re-inclusion), pure-helper cases (count-increase, same-snapshot, nil existing), single and batched derive paths, and the reworked `testLocalStateSurvivesRederivation` correctly narrows to same-message re-derive.

## Open questions
1. Is waking on *self-sent* replies intended "Gmail-style"? (Gmail wakes only on received mail.) M2's draft case is almost certainly not intended.
2. Does the message-window pruner run against snoozed threads in practice (M1)? If pruning skips threads with local state, M1 is theoretical.

## Suggested fixes (not applied)
- M1/M2: in `preservedSnoozeUntil`, compare against a set of message IDs (or a non-draft count) rather than raw `messageCount`, and/or restrict the wake trigger to a new message carrying `UNREAD`/`INBOX` (i.e. actually incoming): `messages.contains { $0.isUnread && !$0.labelIds.contains("DRAFT") && $0.date > existing.lastDate }`-style check would cover both.
- Add tests: draft-save on snoozed thread keeps snooze; prune-then-backfill keeps snooze.

## Verdict
**SHIP** — the stated task (badge/list/notification parity for snoozed unread, wake-on-new-message) is implemented correctly and well-tested. M1/M2 are edge-case false-wakes in the new wake heuristic, worth a fast-follow but not badge-inflation regressions, and their failure mode (thread reappears early) is benign relative to the bug being fixed. Caveat: I was unable to execute the test suite in this session.
```
