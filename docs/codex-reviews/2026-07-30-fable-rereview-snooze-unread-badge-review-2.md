---
date: 2026-07-30 10:36
kind: review
reviewer: Fable (Claude Code subagent via jacq-claude)
target: branch fix/snooze-unread-badge vs main (after M1/M2 fixes)
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260730T103456-93123
git_branch: fix/snooze-unread-badge
git_head: 54adf0e12350b588a7b89bcc71572ed342c29a24
focus: >
  Re-review after addressing M1/M2: wake only on lastInboundDate advance.
---

# Review prompt

Re-review after addressing M1/M2 from prior pass. Complete diff vs main.

# Verbatim Fable review

```
id:	review-20260730T103456-93123
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/snooze-unread-badge
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260730T103456-93123/output.log
---
Test run was not permitted in this session, so pass/fail is unverified — noting that below. Review complete.

# Re-review: snooze unread badge fix + Gmail-style wake (diff vs `main`)

## Findings by severity

### Low

**L1 — Legacy pre-fix rows: stale `snoozeUntil` on already-woken threads self-heals only via `fireDueSnoozes`, but that path re-issues a Gmail `add: ["INBOX"]` call.**
DBs corrupted by the pre-fix bug (reply arrived, INBOX restored, `snoozeUntil` still set in the future) are now correctly excluded from badges by the SQL gate (`SidebarCounts.swift:126-158`) and the notification baseline (`MailStore.swift:3434`), and eventually cleared by `fireDueSnoozes` (`MailStore.swift:4595-4604`), which calls `snooze(thread, until: nil)` → `modifyThread(add: ["INBOX"])` (`MailStore.swift:4570-4572`). For a thread already in the inbox this is a harmless no-op API call, but it's a network write triggered per stale row on one sync tick. Cosmetic/perf only; no correctness impact.

**L2 — `preservedSnoozeUntil` nil-prior branch can spuriously wake after a prune-to-zero → backfill sequence.**
`SyncEngine.swift:843-845`: if `existing.lastInboundDate` is nil, any inbound message wakes the snooze. `lastInboundDate` is maintained by every derive and backfilled by migration v25 (`Database.swift:1204-1238`), so nil normally means pure-outbound and the branch is correct. The only path to a wrong nil is a thread whose messages were all pruned locally while snoozed and later backfilled with *old* inbound mail — then the old message wakes the snooze. Very narrow; snoozed threads are archived (`inInbox=false`, `MailStore.swift:4580`) and re-deriving a zero-message thread typically deletes it. Accept as-is.

**L3 — Promotions/Social lists with `showArchived` can show a snoozed unread row while the tab badge excludes it.**
`MailStore.swift:2617,2627` apply `notSnoozed` only when `!showArchived`, but the promo/social badge counts now always exclude sleeping threads (`SidebarCounts.swift:128-135`). With "show archived" on, a sleeping unread promo row is visible but unbadged. This matches the "badge tracks the default visible list" philosophy and Gmail's behavior; mentioning for completeness only.

### Correctness checks that pass

- **M1 (prior pass) properly fixed**: wake keys strictly off `lastInboundDate` advancing (`SyncEngine.swift:836-844`); `isOwnOutbound` (`SyncEngine.swift:895-906`) excludes DRAFT, SENT-without-INBOX, and from-self-without-INBOX. Draft saves, own sends, and prune count churn all keep the snooze. Same-snapshot re-derive keeps it (`inbound == prior` → not `>` → keep).
- **Precision**: both `inbound` and `prior` derive from stored message/thread rows in the same DB, so sub-second truncation can't produce a false `>`.
- **Message ordering**: `lastInboundDate(messages:)` takes the first non-outbound message and callers pass newest-first (`.order(Column("date").desc)`, `SyncEngine.swift:756`; batch path documents the same at `:856`). Correct.
- **SQL binding**: `notActivelySnoozedSQL` uses exactly one `?`; `hideSQL` interpolates literals only (`SidebarCounts.swift:97`); `count()` prepends the account arg (`SidebarCounts.swift:184`). All four badge queries bind `[now]` correctly.
- **In-memory/SQL parity**: `memberships` now gates inbox/promo/social on `!isActivelySnoozed` (`SidebarCounts.swift:44-47`) with the same `until > now` boundary as the SQL (`<= ?` awake ⇔ `> now` sleeping — boundary instants agree: `until == now` is awake in both).
- **Consistency with list**: badge predicate now matches `notSnoozed` (`MailStore.swift:2563-2564`) — the original Qiyun ghost-badge repro is covered by `testSnoozedUnreadDoesNotInflateInboxBadge`.
- **Notification baseline** (`MailStore.swift:3421-3436`): same gate, prevents a sleeping unread from seeding/notifying. Consistent with badge.

### Test coverage

Good: same-snapshot keep, inbound wake (single + batch derive paths), draft no-wake, own-SENT no-wake, nil-existing, SQL badge counts across primary/promo, membership boundary at/after wake time, reminders preserved through wake. Gap worth adding someday: SENT+INBOX self-echo (reply-all including you) *does* wake — intentional per `isOwnOutbound`'s comment, but untested.

## Open questions

1. Is SENT+INBOX (self-echo counting as activity → wakes snooze) the intended Gmail parity? The `isOwnOutbound` doc says yes for reminders; assuming the same is deliberate for snooze.
2. **Tests were not executed in this session** (command approval denied). Findings are from static review; the suite should be run before merge if it hasn't been on this exact tree.

## Suggested fixes (optional, not applied)

- L1: in `fireDueSnoozes`, skip the remote `add INBOX` when `thread.inInbox` is already true (pure local clear).
- Coverage: add a `preservedSnoozeUntil` assertion for a SENT+INBOX self-echo message documenting the wake-on-self-echo choice.

## Verdict

**SHIP** — both prior M-level caveats are correctly resolved, the wake heuristic is sound and well-tested, and all remaining findings are Low/cosmetic. (Contingent on the test suite passing, which I could not run here.)
```
