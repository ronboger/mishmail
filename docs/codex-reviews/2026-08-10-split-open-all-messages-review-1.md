---
date: 2026-08-10 20:05
kind: fable-iterate review
review_model: claude-fable-5
review_effort: low
job_id: review-20260810T200507-17389
base: main
branch: fix/split-open-all-messages
reviewed_commit: ec4780f
head_at_save: e0271f7
verdict: SHIP
checks: make test → TEST SUCCEEDED, 1400 tests, 0 failures; make build → ok
task: side-by-side compose open all emails + 3-dot toolbar
---

# Review — side-by-side open-all messages + ⋯ toolbar (pass 1)

Note: pass 1 reviewed `ec4780f`. Follow-up `e0271f7` re-applies multi-expand seed after last-card onAppear race (addresses the empty-guard issue the reviewer noted under Medium/stale-id interaction).

id:	review-20260810T200507-17389
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/split-open-all-messages
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260810T200507-17389/output.log
---
Permission deny rule "MultiEdit" matches no known tool — check for typos.
Review complete. Diff is one commit: new `MessageExpandPolicy`, `expandedMessageId: String?` → `expandedMessageIds: Set<String>`, `NavigationStack` wrapper in `splitComposeLayout`, policy tests, project.yml registration.

## Findings

**Medium — new messages arriving during split compose stay collapsed.**
`seedExpandedMessagesIfNeeded()` (ThreadDetailView.swift:823) guards on `expandedMessageIds.isEmpty`, and the refresh path (`onChange(of: store.threadContentToken)` → `refreshMessages` → `applyDetailPayload`) reruns it with a non-empty set. So in `.multiple` mode, a reply that syncs in mid-draft renders collapsed — arguably against the "open all messages" intent, though it does preserve cards the user deliberately collapsed. Decide which behavior you want; if new arrivals should open, `applyDetailPayload` could `applyingExpand` ids not previously seen.

**Low — brief collapse window on cold load in split mode.** `.task(id: thread.id)` resets `expandedMessageIds = []` (line 477) before an awaited (non-warm) payload load. Cards already on screen from the mirror preseed collapse until the payload lands and reseeds. Same pattern existed pre-change with the optional id, so not a regression — just noting it survives.

**Low — stale ids can persist in the set.** After a send/discard changes message ids, `expandedMessageIds` may hold ids absent from `messages`. Harmless today (`contains` lookups only), but the `isEmpty` seed guard means a set holding only stale ids blocks reseeding. Edge case; unlikely in practice.

**Low — test gap.** `MessageExpandPolicyTests` covers the pure policy well (toggle, expand, initial seeds, empty thread). Nothing covers: the seed-vs-`onAppear` ordering in `MessageCard.onAppear` (line 2029), the refresh-path behavior above, or that the split column's toolbar actually mounts under the new `NavigationStack`. The toolbar fix is view-hierarchy behavior that only a UI test or manual run verifies — I did not build or run the app (read-only session), so toolbar mounting is unverified here.

**Info — correctness checks that passed:**
- Single-mode behavior is preserved exactly: `applyingToggle`/`applyingExpand` under `.single` reproduce the old optional-id semantics, and the old `onAppear` last-card fallback is kept with the `isEmpty` guard.
- Ordering race between card `onAppear` (which can pre-populate the set) and the parent seed is resolved correctly by the `expandedMessageIds = []` reset in `.task` before `applyDetailPayload` seeds.
- CID/attachment recovery now loops over all open ids (line 973) and is idempotent via the `*Attempted` sets — no repeated fetch storm on refresh.
- `NavigationStack` is only added in the standalone split layout (ContentView.swift:490), not nested inside the existing `NavigationSplitView` detail column; prev/next buttons correctly hidden in split (`if !splitMode`, line 306).
- project.yml includes the new source file; drafts are correctly excluded from the seed via `ForwardComposer.isLiveDraft`.
- Opening every body at once means one WKWebView per message in split mode — intentional and documented; a very long HTML-heavy thread could get expensive, but that's the feature's stated trade-off.

## Open questions
1. Should a message that arrives while split compose is open auto-expand? (Medium finding above.)
2. Was the split toolbar verified manually on macOS 26? No automated coverage exists.

## Suggested fixes (not applied)
- If yes to Q1: in `applyDetailPayload`, track previously-seen message ids and `applyingExpand` new ones under `.multiple`.
- Optionally prune `expandedMessageIds` to ids present in `messages` on payload apply, which also fixes the stale-id seed-guard edge.
- Add a UI/snapshot test asserting `exitSplitButton` exists in split compose.

**SHIP** — the two behavioral notes are edge cases, not blockers; core logic is correct and unit-tested. Caveat: I did not build or run anything, so the toolbar-mount fix rests on manual verification.
