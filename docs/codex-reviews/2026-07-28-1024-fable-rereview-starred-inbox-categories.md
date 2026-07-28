---
date: 2026-07-28 10:24
kind: review
reviewer: Fable (Claude Code subagent, not a /codex:* command)
target: branch fix/starred-inbox-categories vs main
verdict: ship-it
codex_session_id: n/a
job_id: review-20260728T102218-68178
duration: ~2m 34s
invoked_from: /Users/ronboger/mishmail/.worktrees/starred-inbox-categories
git_branch: fix/starred-inbox-categories
git_head: 3a327a5f53dbbc18dc2171892a0891cef21c5283
diff_size: 5 files, +245 / −10 vs main
focus: >
  Re-review after CategoryHide extract, badge-asymmetry docs, and
  mailbox-scope regression test. Confirm ship-it or remaining fix-required.
prior_review: docs/codex-reviews/2026-07-28-1021-fable-review-starred-inbox-categories.md
---

# Re-review: `fix/starred-inbox-categories` vs `main`

**Verdict: ✅ ship-it.** No fix-required items. All three prior follow-ups landed correctly; the diff introduces no new correctness, security, or test-gap problems. Scope reviewed: `5ff3c81` + `3a327a5`, 5 files, +245/−10.

## 1. Findings by severity

No High/Medium findings. The changes are a faithful refactor plus the intended starred pin-through.

### What I verified

**CategoryHide extraction is faithful and shared (not duplicated)**
- `CategoryHide.apply` (`Store/CategoryHide.swift:12`) reproduces the original promo/social/default branches exactly, adding only the intended `|| Column("isStarred") == true`.
- `applyChips` (`MailStore.swift:2328`) and the legacy structured-view `applyExcludePromotions` (`MailStore.swift:2491`) both route through it — same starred pin at both entry points.
- The third excludePromotions site (`MailStore.swift:2782`) only *builds* `category.hide` via `formUnion`, which then flows through `applyChips → CategoryHide.apply`, inheriting the same behavior. **No divergent copy of the hide SQL remains.**
- `project.yml:134` adds the file to the test target, so tests link the production type.

**Badge asymmetry is intentional and internally consistent**
- `SidebarCounts.memberships` (`SidebarCounts.swift:22`), the unread-badge SQL (`:54`), and `currentUnreadInboxIds` (`MailStore.swift:3248`) all keep Primary-only semantics (`inPromotions=0 AND inSocial=0`). A starred promo shows in the inbox *list* but does not inflate the inbox unread badge. List-membership (CategoryHide) and count-membership (SidebarCounts) are deliberately different axes, documented at all three sites. Coherent.

**Tests exercise production SQL and cover the right cases**
- All cases call `CategoryHide.apply` / `applyExcludePromotions` against a real migrated `DatabaseQueue`.
- `testStarDoesNotOverrideMailboxScope` (`StarredCategoryFilterTests.swift:167`) is the important new guard: it proves the pin defeats only *category tabs*, not mailbox scope — starred trashed/archived promo stays excluded under `inInbox && !inTrash` + CategoryHide. This closes the "star resurrects trash/archive" risk.
- The positional `MailThread(...)` fixture init stops at `reminderAt` and relies on defaults for `inPromotions`/`inSocial` (set afterward), matching `Database.swift:15–44`. Compiles, realistic (STARRED kept in the label blob).

## 2. Open questions (non-blocking)

- **O1 — optimistic predicate ignores category hide.** `threadLeavesCurrentList(.inbox)` (`MailStore.swift:4008`) never consulted category chips, so an unstarred promo is kept optimistically until async reload corrects it; likewise unstarring a pinned promo won't drop it until reload. **Pre-existing** and explicitly best-effort ("async reload is the source of truth", `:3992`). The pin-through makes it marginally more visible but does not regress it. Intentional to leave?
- **O2 — no `keepIds` pin for a just-unstarred thread.** Unlike read/unread (`keepIds`, `:2353`), unstarring a starred promo in the inbox makes it vanish on next reload rather than lingering under the cursor. Likely desired (it no longer qualifies) and symmetric with category-chip behavior — flag only if product wants the linger.

## 3. Suggested fixes

None required. O1/O2 (and the pre-existing substring `labelIds LIKE '%CATEGORY_UPDATES%'` in `CategoryHide.swift:23`, which is safe since the Gmail constants don't collide) are optional polish, not correctness issues.

---

**Ship it.** The prior non-blocking follow-ups are fully resolved, the extracted SQL is the single source of truth, the asymmetry is documented and internally consistent, and the new mailbox-scope test closes the one place the pin-through could have leaked.
