---
date: 2026-08-10 13:05
kind: review
target: branch diff against main (feat/mcp-bulk-vip-multi-group)
verdict: ship-it
model: claude-fable-5
effort: low
requested_model: claude-fable-5
requested_effort: low
job_id: review-20260810T130139-92356
reviewed_commit: 6706f64290c3fbfe377950942d0ffcb3f16decbe
invoked_from: /Users/ronboger/mishmail/.worktrees/feat-mcp-bulk-vip-multi-group
git_branch: feat/mcp-bulk-vip-multi-group
focus: MCP bulk VIP add + multi-group tags
---

## Prompt

Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: mishmail MCP should enable bulk additions to VIP. there should also be a way to tag people with multiple groups.

## Verbatim review

id:	review-20260810T130139-92356
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/feat-mcp-bulk-vip-multi-group
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260810T130139-92356/output.log
---
Permission deny rule "MultiEdit" matches no known tool — check for typos.
All 42 selected tests pass (VIPMembership, MCPRouter, MCPBridge, DatabaseMigration suites; `xcodebuild test -scheme MishMailTests`). The diff delivers both requested features: `add_vips` bulk MCP tool and multi-group tags (junction table `vipSenderGroup`, v34 migration with backfill, union semantics, `set_vip_groups`).

## Findings

**Medium — `add_vip`/`add_vips` default "Suggested" mutates existing VIPs' groups.**
`MCPBridge.resolvedVIPGroups` (MCPBridge.swift:552) substitutes `["Suggested"]` when no group is given, and `addVIPs` unions that into every email, including ones that are already VIPs. Bulk-adding a mixed list without groups silently tags all pre-existing VIPs with "Suggested". Old behavior only touched new rows. An agent doing "make these 50 senders VIP" pollutes existing carefully-tagged VIPs. Suggested fix: apply the "Suggested" default only to newly created senders (or drop the default for `add_vips` and pass `[]` through — the store handles empty groups fine).

**Low — stale-cache group wipe in single `addVIP`.**
`MailStore.addVIP` (MailStore.swift:~95 of diff) decides `existed` from in-memory `vipEmails`, then reads current tags only `if existed`. `addVIPs` correctly checks the DB (`VIPSender.fetchOne`). If the cache is stale (load failure, external write), `writeVIPMembership` deletes the junction rows and replaces membership instead of unioning. Use the DB existence check in both paths.

**Low — `created` flag vs `added` count can disagree.**
`MCPBridge.addVIPs` (MCPBridge.swift:~345) computes `added` from the store's DB-based count but `created` per row from the in-memory `before` set. Same stale-cache scenario yields inconsistent JSON. Cosmetic; align both on one source.

**Low — dual-write `groupName` goes to `nil` on clear.**
`writeVIPMembership` sets `vipSender.groupName = names.first`. Clearing groups via `set_vip_groups []` nulls the denormalized column — correct, but any pre-v34 build opening this DB afterward loses group info entirely. Acceptable given the migration is one-way; noting for awareness.

**Info — minor UX/consistency:**
- `addVIPs` notice picks `firstNew` from the sorted-deduped list, not input order — cosmetic.
- Group names are case-sensitive ("Work" ≠ "work"); `toggleVIPGroup` can produce both tags. Documented in VIPMembership.swift, so intentional.
- Re-adding an existing VIP with no new groups still shows "updated in VIPs" though nothing changed.

## Test coverage

Good: pure-helper tests, migration backfill from a real pre-v34 DB (`migrate(upTo: "v33")`), cascade delete, router dispatch and error paths. Gaps:
- No end-to-end test of `MCPBridge.addVIPs` against a real store (union with existing tags, `added`/`updated`/`skippedInvalid` counts).
- No test of the "Suggested" default (the medium finding above would have surfaced there).
- No test of `MailStore.addVIPs` union behavior on existing VIPs or `activeVIPEmails` with mixed enabled groups at the store level.

## Open questions

1. Is unioning the default "Suggested" onto existing VIPs intended, or should the default apply only to new rows?
2. Should `list_vips`' legacy single `group`/`groupEnabled` fields be kept long-term, or deprecated in the tool description?

**Verdict: SHIP** — the medium finding is a behavior wart worth a follow-up, not a correctness blocker; everything else is minor. Tests pass as run above.
