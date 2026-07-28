---
date: 2026-07-28 10:21
kind: review
reviewer: Fable (Claude Code subagent, not a /codex:* command)
target: branch fix/starred-inbox-categories vs main (commit 5ff3c81)
verdict: ship-it (with non-blocking follow-ups later resolved in 3a327a5)
codex_session_id: n/a
job_id: review-20260728T101713-67343
duration: ~3m 58s
invoked_from: /Users/ronboger/mishmail/.worktrees/starred-inbox-categories
git_branch: fix/starred-inbox-categories
git_head: 5ff3c81
diff_size: 2 files, +204 / −4
focus: >
  Correctness / edge cases (sidebar double-count, show-mode, optimistic star,
  notifications baseline); missed hide paths; mirrored-SQL drift; ship verdict.
---

# Code Review: `fix/starred-inbox-categories` vs `main`

**Scope reviewed:** commit `5ff3c81` — `MailStore.swift` (+15 lines across 2 query paths), new `StarredCategoryFilterTests.swift` (193 lines). Static review only; I did not run `xcodebuild test` (noted under Open Questions).

**Verdict: ✅ ship-it** on the core change, with **two non-blocking follow-ups** I'd recommend before or shortly after merge (test-durability refactor + a UX consistency decision on the unread badge). The list-filter change itself is correct and complete across every list path.

(See full verbatim review in jacq-claude job log `review-20260728T101713-67343`. Follow-ups applied in `3a327a5` and confirmed ship-it in re-review `2026-07-28-1024-fable-rereview-starred-inbox-categories.md`.)
