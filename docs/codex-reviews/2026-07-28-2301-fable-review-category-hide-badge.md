---
date: 2026-07-28 23:01
kind: review
reviewer: Fable (Claude Code subagent via jacq-claude, not a /codex:* command)
target: branch fix/category-hide-badge vs main (commit 25eba439fbcaff24afbf4c7516eb7be5bad6c7c6)
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260728T225917-31008
duration: ~2m
invoked_from: /Users/ronboger/mishmail/.worktrees/category-hide-badge
git_branch: fix/category-hide-badge
git_head: 25eba439fbcaff24afbf4c7516eb7be5bad6c7c6
diff_size: 4 files, +242 / −58
focus: >
  Inbox badge must exclude Updates/Forums when Categories "do not contain"
  hides them; Categories popover should not require horizontal scroll.
---

# Review prompt

Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: When the Categories filter is 'do not contain' including Updates (and Forums), the email counter (sidebar Inbox badge / dock badge) still counted those threads as if they were primary inbox mail. Also the Categories popover required horizontal scrolling of selected chips — make category picking more ergonomic.

Diff: SidebarCounts + MailStore pass inbox hide set for Updates/Forums into primary badge; CategoriesPopover is a 2x2 grid of pills instead of chip strip + checkboxes.

# Verbatim Fable review

id:	review-20260728T225917-31008
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/category-hide-badge
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260728T225917-31008/output.log
---
Review complete. Static analysis only — the harness denied `swift test`, so I could not execute the suite (noted below).

## Findings

**LOW-1 — "contain" mode badge mismatch (pre-existing, but now more visible).**
`inboxBadgeHideCategories` (MailStore.swift:2725-2733) reads only `chips.category.hide`. In "contain" mode (`exclude = false`, `show` populated — MailStore.swift:2386-2397) the list shows only the chosen categories, but the badge still counts all non-promo/social primary mail. This is pre-existing behavior for `show` and the list applies `hide` in both modes (MailStore.swift:2385), so the new code is internally consistent — but the task framing ("counter matches list") remains unmet for contain mode. Acceptable as out of scope; worth a follow-up note.

**LOW-2 — Per-account view hide set applied to unified badge.**
In `inboxBadgeHideCategories`, `.account` uses live `chips.category.hide` — the per-account view's pick — and that set feeds both the unified sidebar `counts["inbox"]` and the dock badge (which may span all accounts via `badgeAccount = nil`). If account A's inbox hides Updates but the global inbox pick doesn't, viewing account A shrinks the unified Inbox badge for all accounts. Symmetrically, the non-inbox fallback always uses the global `.inbox` persisted pick even when `badgeAccount` is a single account with its own saved pick (`categoryFilter.<key>` is per view, MailStore.swift:169-174). Small, view-dependent badge drift; the doc comment claims the fallback "still matches what Inbox shows," which is only true for the unified inbox.

**LOW-3 — Substring `LIKE` vs exact-token divergence.**
`primaryHideSQL` uses `labelIds LIKE '%CATEGORY_UPDATES%'` (SidebarCounts.swift:78-84) while `isHiddenFromPrimary` uses exact token match on `thread.labels` (SidebarCounts.swift:65-71). A hypothetical label containing the category id as a substring would diverge (SQL hides, optimistic doesn't). Gmail ids make this theoretical, and it deliberately matches `CategoryHide.apply`'s existing LIKE style (CategoryHide.swift:35), so consistent-by-design. No action needed.

**Non-issues verified:**
- SQL interpolation is safe — only whitelisted constants from `primaryHideableCategories` pass the `where` clause before interpolation (SidebarCounts.swift:77).
- Starred hidden Updates stay visible in the list (star pin-through, CategoryHide.swift:35-37) but leave the badge — intentional, matches the documented promo/social precedent, and explicitly tested (`testMembershipsRespectUpdatesHide`).
- Badge refresh path is live: chip edits → `.onChange(of: store.chips)` → `reloadThreadsDebounced()` (ContentView.swift:207) → `fetchSidebarCounts` with the new hide set → `Notifier.setBadge`. Optimistic single-thread updates use the same hide set in `memberships` (MailStore.swift:3968-3971), so optimistic and reconciled counts agree.
- All call sites of `fetchSidebarCounts`/`memberships` were updated; the default `hideCategories: []` preserves old behavior for any untouched caller.
- Popover grid: covers all four categories in fixed order, toggling edits `filter.categories` which routes to `hide`/`show` per mode — behavior-equivalent to the removed checkboxes; the removed chip strip was purely redundant UI. Persistence via chips `didSet` unaffected.

**Test coverage:** Good — `testPrimaryBadgeRespectsUpdatesForumsHide` covers no-hide/partial/all-hide including the multi-label thread and promo-stays-on-tab, and `testMembershipsRespectUpdatesHide` covers the optimistic path including starred. Gap: no test for `primaryHideSQL` with a hide set containing only promo/social (should return empty string) — indirectly covered by `hideAll`, but a direct unit assert would be cheap.

## Open questions
1. Is the LOW-2 cross-account badge drift acceptable, or should the dock badge always use the badge account's own saved pick?
2. Should "contain" mode eventually drive the badge too (LOW-1), or is the badge defined as "primary tab unread" regardless of contain filters?

## Suggested fixes (not applied)
- LOW-2: in `inboxBadgeHideCategories`, resolve the fallback from the badge account's view when `badgeAccount` is a single account; or document the unified-pick choice.
- Add a one-line test: `XCTAssertEqual(SidebarCounts.primaryHideSQL(hide: ["CATEGORY_PROMOTIONS"]), "")`.

**Verdict: SHIP** — correct for the stated task, safe SQL, consistent optimistic/DB paths, well tested. (Caveat: tests reviewed statically; run `swift test --filter ThreadDenormTests` to confirm green.)
