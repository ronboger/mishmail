---
date: 2026-07-26 22:05
kind: review
reviewer: Fable (Claude Code subagent, not a /codex:* command)
target: commit 558411e "Show draft count badge in the sidebar"
verdict: ship-it (0 blockers, 1 should-fix known-lag, 1 nit)
codex_session_id: n/a
job_id: n/a
duration: n/a
invoked_from: /Users/ronboger/berkeley/ron_perfect_email
git_branch: feat/sidebar-drafts-count
git_head: 558411e182279d3d95a04603325c3289aeca56ce
diff_size: 1 file, +2 / −1
focus: >
  Count predicate vs Drafts list filter; optimistic vs sync badge updates;
  thread-vs-draft counting; multi-account scope; zero-hide convention.
---

# Review of `feat/sidebar-drafts-count` (commit 558411e)

Note: the commit lives in the `.worktrees/sidebar-drafts-count` worktree, not on `main` — I reviewed it there. **No blockers.** The wire-up is correct and consistent; the only real observations are about update latency and one thread-vs-draft counting nuance.

### Clean areas (verified, no findings)

1. **Count vs list filter — exact match.** [SidebarCounts.swift:72](Sources/MishMail/Store/SidebarCounts.swift:72) counts `inDrafts = 1 AND inTrash = 0`; the Drafts list query at [MailStore.swift:2451](Sources/MishMail/App/MailStore.swift:2451) filters the identical predicate, including the account scoping: both apply `accountId == activeAccount` only when an account is active, so unified view counts all accounts and scoped view counts one — matching what the list shows. Neither excludes spam or applies snooze, so they can't diverge there either.
2. **Zero hides the badge** — the existing `.badge((badge ?? 0) > 0 ? ... : 0)` convention handles it; `SidebarCounts.fetch` always populates the `"drafts"` key so the dictionary lookup never goes stale-nil after a reload.
3. **Semantics.** Total-not-unread matches the Scheduled row directly below it (`scheduledSends.count`, also a total), so the section already mixes unread badges (Inbox) with total badges (Scheduled); Drafts joining the total camp is coherent and matches Notion Mail. The commit comment states the intent in place.
4. **Optimistic deltas** — `SidebarCounts.memberships` includes `drafts` with the same in-memory predicate, and `applyOptimisticSidebarCountDelta` ([MailStore.swift:3866](Sources/MishMail/App/MailStore.swift:3866)) correctly skips other-account threads in scoped view. Trashing a draft-only thread from the list will decrement the badge in the same frame.
5. **Test coverage exists** at the store level: `ThreadDenormTests` asserts `all["drafts"] == 1` through the real fetch, and `SidebarCountsIndexTests` covers the SQL/index. A UI test for the one-line wire-up would add little; I don't think one is needed.

### Findings

**Should-fix (suspected, arguably known-lag): compose-lifecycle draft changes only update the badge on sync, not optimistically.** The optimistic delta path fires on *thread mutations* (`mutateThreads`), but draft create/replace/discard go through `saveDraft`/`deleteUnderlyingDraft`, which write via the Gmail API and rely on `sync(accountId:)` → `reloadThreads` → `fetchSidebarCounts` to refresh the count. Two consequences:
- Silent autosaves (`silent: true`, so `shouldSync == false`) create a real remote draft but the badge doesn't move until the compose session ends and `syncDraftMailbox` runs. So while typing a brand-new draft, the badge lags by up to the whole compose session.
- After send or discard, the badge clears only when the post-action sync lands (typically a second or two). During the 10s undo-send window the draft row still exists, so the badge keeps counting it — which is arguably *correct* (undo restores it), but worth knowing it's emergent rather than designed.

This is inherent to the existing draft lifecycle, not introduced by this commit; if the lag bothers you in practice, the fix is a small optimistic bump in `saveDraft`/`deleteUnderlyingDraft`, not in the UI.

**Nit (verified): the badge counts threads, not drafts.** `COUNT(*)` over `thread` means a thread holding two drafts (e.g. two reply drafts accumulated in one conversation) shows as 1, and a reply draft on an inbox thread counts that whole thread. That matches what the Drafts *list* shows (rows are threads), so list and badge agree — which is the property that matters — but "3" means "3 threads containing drafts," not "3 drafts." Notion Mail behaves the same way; leaving as-is is fine.

Nothing to change in the commit itself — it's a correct one-liner sitting on a data path that was already sound.
