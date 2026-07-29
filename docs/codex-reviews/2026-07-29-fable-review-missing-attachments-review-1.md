---
date: 2026-07-29 16:44
kind: review
reviewer: Fable (jacq-claude, model=claude-fable-5, effort=low)
target: fix/missing-attachments-recovery vs main (pass 1)
verdict: SHIP (with MEDIUM follow-ups addressed in pass 2)
job_id: review-20260729T164429-48684
invoked_from: /Users/ronboger/mishmail/.worktrees/missing-attachments-recovery
git_branch: fix/missing-attachments-recovery
git_head: cde3f29366c53986138eb190b35d5734902974bc
focus: Missing attachment chips for Criocore / Let's chat stale cache
---

# Fable Review — missing attachments recovery (pass 1)

```
id:	review-20260729T164429-48684
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/missing-attachments-recovery
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260729T164429-48684/output.log
---
## Review: fix/missing-attachments-recovery (cde3f29 vs main)

### Findings by severity

**MEDIUM-1 — Repair flag set despite partial fetch failure, permanently stranding the exact bug being fixed**
`SyncEngine.swift:128-131` sets `backfill.attachments.<account>` unconditionally after `repairMissingAttachments` returns. But the loop (`SyncEngine.swift:~377`) consumes only `report.messages` from `getMessages(ids:format:)`, which by design does **not throw** for per-id failures — it returns `notFoundIds` and `retryExhaustedIds` (`GmailClient.swift:314-321`). A rate-limited pass can leave some `hasAttachment=0` rows unrepaired, yet the flag is set, and `shouldRecoverAttachments` then returns `false` for those on open (flag-false + repair-completed branch). Those messages become permanently unrecoverable — the exact user-visible bug. Fix: only set the flag when `retryExhaustedIds` was empty across all pages (or accumulate and skip flag-set on any exhaustion).

**MEDIUM-2 — Stale rows outside the sync window are gated off after the one-shot pass**
The repair query intersects with `windowQuery` (`newer_than:90d` by default). Locally-cached mail older than the window exists — the starred backfill (`SyncEngine.swift:114-119`) pulls `is:starred` all-time. A starred, stale, `hasAttachment=0` message older than 90d is never listed by the repair query, and after the flag is set it's excluded from open-time recovery too. Consider running repair with `has:attachment is:starred` as a second query, or not intersecting with the window for the one-shot.

**LOW-1 — Pre-repair open-time recovery full-fetches every attachment-free message opened**
Before the sync repair completes (first launch after update, or a user who never lets sync finish), `shouldRecoverAttachments(false, 0, false) == true`, so *every* opened message with no chips — i.e., most mail — triggers a full-format re-fetch + upsert + thread re-derive. Bounded per-session by `attachmentRecoverAttempted`, so acceptable, but worth knowing this is one extra API call per unique open until sync runs once.

**LOW-2 — MEDIUM-1 interacts with `listed < limit` pagination**
`while pageToken != nil && listed < limit` counts listed ids, not repaired; with `syncWindowDays == 0` the 50 000 cap could truncate a very large `has:attachment` corpus silently, with the flag still set. Same remedy as MEDIUM-1 (don't set flag when work was provably left).

**LOW-3 — Redundant/cosmetic**: `if repaired > 0` inside the `!needRepair.isEmpty` branch is always true at that point (`SyncEngine.swift:~383`); progress line re-emits every page — fine, just noisy.

**Correct things worth noting (verified, not findings):**
- `refetchMessageFull` now calls `SyncEngine.deriveThreads` → paperclip denorm updates on open-time recovery. ✔
- UI merge preserves session CID-inlined HTML and only rebuilds prep when not inlined (`ThreadDetailView.swift:832-843`). ✔
- Cross-account isolation and dedupe in `filterGmailIdsNeedingAttachmentRepair` are SQL-parameterized, ≤100 placeholders per page (under SQLite's 999 limit). ✔
- DB write happens in `MailStore.refetchMessageFull` regardless of whether the view is still open — the UI-close guard only skips state updates, not persistence. ✔
- `attachmentRecoverAttempted` inserted before the Task, so one attempt per session even on network failure — matches the documented intent. ✔

### Open questions
1. Is stranding retry-exhausted messages behind the completed flag acceptable, or should the flag wait for a fully clean pass (my recommendation)?
2. Should starred/out-of-window mail be included in the one-shot (see MEDIUM-2)?
3. `hasAttachment=1` rows with wiped attachment rows are healed only on open (repair query filters `hasAttachment = 0`) — intentional? (It's fine — open-time always recovers that shape ungated — just confirming.)

### Test gaps
- No test for `repairMissingAttachments` itself (pagination, limit cutoff, flag semantics on partial failure) — it's `private` and network-coupled; the pure helpers are tested but MEDIUM-1's behavior is exactly the untested seam.
- No test asserting the thread `hasAttachment` denorm flips after open-time recovery (the deriveThreads addition).
- Policy tests cover all 4 quadrants of `shouldRecoverAttachments`. ✔

### Suggested fixes (not applied — read-only)
1. Track `var exhausted = 0` in the repair loop, add `report.retryExhaustedIds.count`; return it and only `UserDefaults.set(true, …)` when `exhausted == 0` **and** the pagination completed (`pageToken == nil`).
2. Optionally run a second repair sweep with `has:attachment is:starred` (no window) to cover starred old mail.
3. Drop the redundant `repaired > 0` check.

### Verdict

**SHIP** — the core fix is correct, well-gated, and matches the task (one-shot sync repair + open-time recovery + thread re-derive). MEDIUM-1 is a real edge that silently defeats the fix under rate-limiting and is a ~3-line change; strongly recommend landing it as an immediate follow-up before the flag gets set on real accounts.
```
