---
date: 2026-07-29 16:48
kind: review
reviewer: Fable (jacq-claude, model=claude-fable-5, effort=low)
target: fix/missing-attachments-recovery vs main (pass 2)
verdict: SHIP
job_id: review-20260729T164653-50807
invoked_from: /Users/ronboger/mishmail/.worktrees/missing-attachments-recovery
git_branch: fix/missing-attachments-recovery
git_head: d558eded777d5851197df9ac22a5d30a36cebfa6
focus: Re-review after MEDIUM-1/2 fixes (flag gate + starred sweep)
---

# Fable Re-review — missing attachments recovery (pass 2)

```
id:	review-20260729T164653-50807
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/missing-attachments-recovery
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260729T164653-50807/output.log
---
## Re-review: attachment recovery vs `main` (pass 2)

Scope reviewed: `git diff main` — SyncEngine.swift (+152), MailStore.swift (+29), ThreadDetailView.swift (+53), AttachmentRecoveryTests.swift (new, 204).

### MEDIUM-1 (flag set despite retry exhaustion) — CLOSED ✅

`SyncEngine.swift:396-412` — `exhausted += report.retryExhaustedIds.count` accumulates across both sweeps and all pages; `SyncEngine.swift:427` sets `completedCleanly = false` if `exhausted > 0`. The flag write at `SyncEngine.swift:133-135` is gated on `report.completedCleanly`. Any thrown error (listMessages/getMessages/db) propagates out of `sync()` before line 134, so the flag is also never set on hard failure. Confirmed closed.

### MEDIUM-2 (out-of-window starred mail stranded after flag set) — CLOSED ✅

`SyncEngine.swift:372-380` — second sweep `has:attachment is:starred` runs unconditionally (no window clause), and starred mail is retained by `pruneLocalMail` (per `SyncEngine.swift:101-110` comment), so the repair corpus covers it before the one-shot flag is set. Confirmed closed.

### Findings

**LOW-1 — Perpetual re-list when corpus permanently exceeds `windowLimit`.**
`SyncEngine.swift:414-419`: if either sweep's listed count hits the cap with pages remaining, `completedCleanly = false` and the flag is never set — so *every* sync re-lists up to `windowLimit` ids across both sweeps (and, per LOW-2 below, re-fetches any never-converging ids full) forever. This is intentional per the design (open-time recovery stays enabled while flag is false), but it never converges for large mailboxes: repairs only ever touch the first-`limit` listed ids and the same cap trips each pass. Consider a per-sweep resume cursor or a "truncated but progressed" counter if this shows up in API quota. Not blocking.

**LOW-2 — Non-converging repair candidates are re-fetched full on every pass until the flag is set.**
`filterGmailIdsNeedingAttachmentRepair` (`SyncEngine.swift:323-341`) selects on `hasAttachment = 0`. A message Gmail lists under `has:attachment` whose re-parse still yields `hasAttachment = 0` (e.g. parser treats its only part as inline, no filename) will be re-fetched `format: "full"` on every repair pass. Bounded to one wasted pass when the flag gets set; unbounded when combined with LOW-1. Cheap mitigation: also skip ids already re-fetched this pass — or track a per-id attempted marker. Not blocking.

**LOW-3 — UI merge can regenerate body prep with a raw (non-CID-inlined) body ordering nit.**
`ThreadDetailView.swift:829-843`: if `cidInlinedHTMLById[id]` exists, `merged.bodyHTML` is replaced with the inlined HTML but `bodyPrepByMessageId` is deliberately left alone — correct. The `nil` branch regenerates prep from the freshly fetched body — also correct. No bug; noting I checked the interleave with `resolveCIDImagesIfNeeded` (recovery kicks first at `ThreadDetailView.swift:793,807,927`, and `cidResolveAttempted` is a separate set, so a recovery landing after CID resolve is preserved via the inlined-HTML guard). OK as written.

**INFO — Double policy check is redundant but harmless.** `shouldRecoverAttachments` is evaluated in both the view (`ThreadDetailView.swift:817-821`) and `MailStore.recoverAttachmentsIfNeeded` (`MailStore.swift:5348-5355`). The store re-check uses the same possibly-stale `message.hasAttachment` snapshot passed in, so it adds defense only against callers that skip the view gate. Fine.

**Tests** — good coverage of the pure surfaces: filter SQL (dedupe, cross-account isolation, healthy/unknown skip), policy truth table (all 4 quadrants), and parser regression pins for the two real-world bug shapes. Gap (acknowledged by design): no integration test exercising `repairMissingAttachments`'s pagination/cap/exhaustion paths — `completedCleanly` gating is only pinned structurally (`testRepairReportCompletedCleanlyMeansFlagSafe`, which asserts nothing about the loop logic). Acceptable given the actor/client seams, but the `listed >= limit && pageToken != nil` branch is the one piece of non-trivial logic with zero test execution.

### Open questions

1. Is the per-sweep `windowLimit` cap (vs. the star backfill's flat 3000 at `SyncEngine.swift:116`) intentional for the starred sweep? A heavy-starred mailbox with a small window (`limit = max(3000, days*60)`) could trip LOW-1 on the starred sweep alone.
2. Do deleted-on-server ids ever land in `retryExhaustedIds` (404 vs. rate-limit)? If yes, a mailbox with locally-cached-but-deleted `has:attachment` mail could keep `completedCleanly` false indefinitely — worth confirming `getMessages` classifies 404 as skip, not exhaustion.

### Verdict

**SHIP.** Both pass-1 MEDIUMs are demonstrably closed with correct gating; remaining findings are LOW/INFO convergence-cost concerns for pathological mailbox sizes, all fail-safe (flag stays unset → recovery paths stay active), none data-corrupting.
```
