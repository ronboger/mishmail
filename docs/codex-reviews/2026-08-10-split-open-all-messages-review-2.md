---
date: 2026-08-10 20:10
kind: fable-iterate review
review_model: claude-fable-5
review_effort: low
job_id: review-20260810T201009-20724
base: main
branch: fix/split-open-all-messages
reviewed_commit: af79081
head_at_save: ae1b756
verdict: SHIP
notes: Medium finding (re-open collapsed on refresh) fixed in ae1b756
checks: make test → 1400 tests, 0 failures
---

# Review — side-by-side open-all messages (pass 2)

id:	review-20260810T201009-20724
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/split-open-all-messages
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260810T201009-20724/output.log
---
Permission deny rule "MultiEdit" matches no known tool — check for typos.
**Verdict: SHIP** — one medium behavior finding, nothing blocking. Policy tests run and pass (8/8, `xcodebuild -scheme MishMailTests -only-testing:…/MessageExpandPolicyTests test` → TEST SUCCEEDED).

## Findings

**Medium — refresh re-opens cards the user collapsed in split mode.**
`Sources/MishMail/UI/ThreadDetailView.swift:789` — the non-empty refresh path computes `missing = live.subtracting(expandedMessageIds)` and force-opens all of it. That set contains not only newly arrived messages but also any card the user manually collapsed via `toggleExpanded`. So in side-by-side compose, collapse a long card, then any `threadContentToken` bump (background sync of this thread) or `suppressedDraftMessageIds` change (open/close another draft — `ThreadDetailView.swift:549` triggers refresh unconditionally) pops it back open, plus refires `loadBodyIfNeeded` for it. The commit message says "open newly arrived messages"; the implementation opens "all not currently open". Fix: diff against the pre-merge message ids, not the expanded set — capture `let prior = Set(messages.map(\.id))` before `messages = merged`, then `missing = live.subtracting(prior)`.

**Low — suppression-change refresh runs the multi-open path for no content change.**
`ThreadDetailView.swift:549-551` refreshes on every `suppressedDraftMessageIds` change even when this thread has no drafts; combined with the finding above it's the cheapest way to hit the reopen bug. Guarded by `merged != messages` (`:771`) so it's usually a no-op — harmless once the first finding is fixed.

**Notes / verified OK**
- Seed race fix (`seedExpandedMessagesIfNeeded`, `:843`): in `.multiple` the full seed unconditionally overwrites the last-card `onAppear` partial set; `onAppear` can only fire before `.task` when `init` preseeded messages from the mirror, and `.task` then resets and re-seeds. Correct. `.single` keeps the `isEmpty` guard so it doesn't fight the onAppear default. Correct.
- Prune of stale ids (`:784-785`) reads `nonDraftMessageIds` after `messages = merged`; @State reads back immediately, so it prunes against the fresh set. Correct.
- `MessageExpandPolicy` is pure and matches the UI usage; single call site of `MessageCard` passes the real policy, so the `.single` default in the init (`:1533`) is dead-but-harmless. No stale `expandedMessageId` references remain.
- ContentView `NavigationStack` wrap keeps the same `ThreadDetailView` structural position, and split vs reading pane are distinct view identities, so `.task(id:)` re-runs on split entry/exit and the policy seeds correctly each way.
- Split mode intentionally accepts N live WKWebViews; changelog states the tradeoff.

## Open questions
- Is reopen-on-refresh in split perhaps intended ("draft always sees the full conversation", per the comment at `:786`)? If so, say that in the changelog instead of "newly arrived", and the finding downgrades to docs. My read of commit af79081's message is that only new arrivals were meant to open.

## Suggested fix (not applied — read-only)
In `refreshMessages()`, before the merge: `let priorIds = Set(messages.map(\.id))`; in the else branch use `let missing = live.subtracting(priorIds)` (keep the existing intersection prune). Add a `ThreadRefresh`-level test covering "collapsed card stays collapsed across refresh; genuinely new id opens".
