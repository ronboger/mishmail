---
date: 2026-07-28 14:41
kind: review
reviewer: Fable (jacq-claude, claude-fable-5)
target: branch fix/unstar-stickiness vs main (commit 5ada495)
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260728T143921-34379
reviewed_commit: 5ada495898f21c5a9a21fe7bda7570e464828246
invoked_from: /Users/ronboger/mishmail/.worktrees/unstar-stickiness
git_branch: fix/unstar-stickiness
focus: >
  Unstar stickiness under category hide / Starred / is:starred / starredOnly.
  Correctness, regressions, test coverage. SHIP or NOT READY.
---

# Prompt

```
[jacq-claude] Mode: READ-ONLY. Do not modify project files. Analyze and report only.

You are a careful code reviewer. Focus on correctness, security, edge cases, and test gaps. Be specific (file:line).
Compare against git ref 'main' (diff / log as needed).
Focus: Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: when I unstar something and it's not in the current categories, it removes the thread from view entirely. I will often want to continue working on that email, even if I unstar it. Fix and make sure the logic applies in other places we may care about starring things.

Expected: starStateKeepIds stickiness (like read-state keepIds) so just-unstarred threads stay listed under category hide, Starred mailbox, starredOnly saved views, and is:starred search until the view/filter changes. Trash/archive must still remove the row.

Deliver:
1. Findings ordered by severity with evidence
2. Open questions
3. Suggested fixes (do not apply unless write mode was requested)

Do not modify files unless explicitly told to write.
```

# Review

id:	review-20260728T143921-34379
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/unstar-stickiness
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260728T143921-34379/output.log
---
This was a read-only review task, not implementation planning, so I'll deliver the report directly.

# Review: unstar stickiness — `fix/unstar-stickiness` vs `main`

One commit (`5ada495`), touching `MailStore.swift`, `CategoryHide.swift`, plus a new test file and extensions to an existing one.

## Findings by severity

### LOW 1 — `label:starred` search and STARRED-label view bypass stickiness
`starStateFilterActive` arms only via `SearchQuery.parse(...).starred`, which matches the literal `is:starred` token only (`SearchQuery.swift:83-84`). But star membership can also gate a list through the label path: `MailStore.swift:2572` maps the `STARRED` system label to `isStarred = 1` in `filterThreads(matchingLabelIds:)` with no keepIds OR-clause. A user searching `label:starred` (or viewing a STARRED label via the `.label` mailbox case, `MailStore.swift:2482+`) who unstars a row still sees it vanish. Narrow, arguably out of scope of the requested surfaces; read-state keepIds has the analogous gap, so this is parity, not a regression.

### LOW 2 — Pins survive filter *edits* while a star gate stays active
`starStateKeepIds` clears on view change (`MailStore.swift:266-267`), account switch (`1218-1219`), and on reload when no star gate is active (`1964`). But changing *which* filter is active — e.g. swapping hide from Promotions to Social, or committing a *different* `is:starred` search — keeps existing pins. Spec said "until the view/filter changes"; strictly it's "until no star-gated filter is active." This exactly mirrors `readStateKeepIds` behavior, so I'd call it intended parity.

### LOW 3 — `starStateFilterActive` over-arms on modern saved views with `excludePromotions`
`MailStore.swift:1300-1310` checks `v.excludePromotions` inside the chipsJSON branch, but `applyExcludePromotions` only runs on the *legacy* (no-chipsJSON) path (`2523-2526`). A modern saved view with a stale `excludePromotions=true` arms the pin unnecessarily. Harmless — extra ids flow into `CategoryHide.apply` with empty `hide`, which is a no-op — but slightly imprecise.

### INFO — Correctness verified across the required surfaces
- **Category hide**: `CategoryHide.apply`/`applyExcludePromotions` OR in `keepIds` per hidden category (`CategoryHide.swift`); threaded through `applyChips` for both reload and loadMore pagination (`MailStore.swift:2083-2088`, `2264-2270`).
- **Starred mailbox**: baseQuery `.starred` (`2475-2477`) and optimistic leave-list (`4081-4083`) both honor the keep set.
- **starredOnly saved views**: both chipsJSON and legacy paths (`2512-2515`, `2524-2527`).
- **is:starred search**: query (`2042-2046`) and optimistic leave-list (`4057-4060`).
- **Trash/archive still removes the row**: leave-list checks trash *before* the starred case in search (`4061` location check) and via `t.inTrash` (`4063`); `.remove` drops the pin so it can't resurrect (`4007-4012`); `inTrash == false` still ANDed in `.starred` baseQuery. Test `testKeepIdsDoNotResurrectTrashOrArchive` covers this.
- **Pin-before-mutate ordering** is correct in both `toggleStar` (`4324-4326`) and `toggleStarChecked` (`4335-4338`), matching the read-state comment contract at `3955-3963`. Bulk unstar pins all targets; bulk star pins none — correct, since `starring` is true if any target is unstarred.
- **Only unstar paths** are `toggleStar`/`toggleStarChecked` — all UI entry points (list row, context menu, detail toolbar, command palette, `s` key at `3448-3450`) route through them. `toggleLabel` via the LabelPicker only offers user `Label_*` labels, so it can't unstar.
- Clearing sites have full parity with `readStateKeepIds` (verified by grep — every removeAll/insert/remove site is paired).

## Test coverage
Good: new `StarUnstarStickinessTests` (250 lines) covers all four surfaces plus the gate and trash-exclusion; `StarredCategoryFilterTests` extended with keepIds cases exercising *production* `CategoryHide` SQL. Honest caveat in the test file that Starred/search/savedView queries are mirrored copies, not production code — acceptable given the hostless test target, and the CategoryHide tests do hit production SQL.

**Caveat: I could not execute the test suite — the `swift test` command was declined in this read-only session.** Findings are from static analysis only.

## Open questions
1. Should `label:starred` search get the same stickiness (LOW 1), or is `is:starred` the only supported syntax worth covering?
2. Is remote-sync unstar (another client unstars; sync drops the row on next reload) intended to bypass stickiness? Current behavior: yes, it bypasses — which seems right for background changes, but worth confirming.

## Suggested fixes (not applied)
- LOW 1: in `filterThreads(matchingLabelIds:)`, extend the `"STARRED"` case to `isStarred = 1 OR id IN (starKeepIds)` and add `label:starred`/system-label detection to `starStateFilterActive` — only if you care about that path.
- LOW 3: move the `v.excludePromotions` check into the legacy (non-chipsJSON) branch of `starStateFilterActive`.

# Verdict: **SHIP**

The implementation is a faithful, well-scoped port of the read-state keepIds pattern; all requested surfaces are covered, trash/archive removal is preserved and tested, and the only findings are low-severity edge gaps that mirror pre-existing read-state behavior. (Recommend running `swift test` before merge since I couldn't execute it here.)
