---
date: 2026-07-30 16:11
kind: fable-review
target: branch fix/discard-draft-conversation vs main
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260730T161130-11734
reviewed_commit: 86a275c9a010326dbcc74101acd120fd850a78e0
invoked_from: /Users/ronboger/mishmail/.worktrees/discard-draft-conversation
git_branch: fix/discard-draft-conversation
focus: Fix Discard on conversation-view draft cards not removing the draft
---

# Fable Review Pass 1 — discard draft conversation

**Prompt:** Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: Fix Discard on conversation-view draft cards not actually removing the draft. User reported Discard does nothing (example: multiple draft cards on a thread for Anna/LPA amendment). Fix should make Discard remove the draft from the open conversation.

## Verbatim review

## Review: Fix Discard on conversation draft cards (86a275c vs main)

### Findings by severity

**Medium**

1. **Discarded drafts become invisible in the Trash view** — `ForwardComposer.readingPaneMessages` is now applied unconditionally in `messages(inThread:)` (MailStore.swift:2828, :2896), `ThreadDetailPayload.suppressingDrafts` (ThreadDetailCache.swift:265-272), and `ThreadDetailView` (ThreadDetailView.swift:197). Per `SyncEngine.trashDraftFlags`, a thread whose messages are all `DRAFT TRASH` gets `inTrash = true` and appears in the Trash list — but opening it now renders an empty reading pane, because every row is filtered as a discarded draft. Combined with the `isDraftOnly` change (MailStore.swift:5058-5062, now returns `false` for such threads, so it no longer hops into compose either), a trashed-draft thread is a click-to-nothing. Gmail shows discarded drafts in Trash; this diff hides their content everywhere.

2. **Remote-delete failure silently diverges local from server, then sync resurrects the card** — `deleteUnderlyingDraft` (MailStore.swift:5116-5133) removes the local row first, then does best-effort remote delete. If `listDrafts`/`deleteDraft` throws (offline, token expiry), the server draft survives and the next periodic sync re-inserts it — the card "comes back" with no clear cause beyond a one-shot `lastError` string (and nothing at all on the `silent: true` paths: MailStore.swift:4896, :4999, ComposeView.swift:442). No retry/queue. For the send path (4896) this means Gmail Drafts can keep a stale copy of already-sent content, which is exactly what the ComposeView.swift:438-443 comment says must not happen. Previously this failure mode existed too, but the new code's comment ("Local already gone — report without resurrecting the card") overstates what it guarantees.

**Low**

3. **`removeLocalDraftMessage` selection side effect on silent paths** — MailStore.swift:5162-5166: when the thread is deleted with `refreshList == false` and it was selected, `selectedThreadId = threads.first?.id` jumps selection to the top of the list. On the send path (silent), the user just sent from a draft-only thread they may be viewing; instead of staying put until sync re-creates the thread with the sent message, the view yanks to an unrelated thread. Consider leaving selection nil or deferring to the post-send `sync`.

4. **Sync race window** — non-silent discard: local row deleted → `listDrafts` round-trip → `deleteDraft` → `sync`. A concurrent periodic sync landing in that window re-inserts the draft row briefly (self-heals on the follow-up sync, but the card can flicker back).

5. **Cursor affordance mismatch** — DraftMessageCard: `onHover` pushing `NSCursor.pointingHand` still covers the whole card (ThreadDetailView.swift:1308) while the tap-to-edit target is now only the inner VStack; hovering Continue/Discard shows a pointing hand implying whole-card tap. Cosmetic.

6. **Test gap on the core mutation** — the actual fix's riskiest code, `removeLocalDraftMessage` (row delete → thread delete vs. `deriveThreads` re-derivation → `ThreadLabels.rewrite`), has no test. All new tests cover the pure helpers (`isLiveDraft`, `readingPaneMessages`, `remoteDraftId`), which were unlikely to be wrong. A GRDB in-memory test of "last draft in thread → thread row gone; draft among sent → thread re-derived, `inDrafts` cleared" would cover the regression surface (thread accidentally deleted on the send/replace silent paths is the scary one).

### Open questions

- Is hiding `DRAFT TRASH` rows in the **Trash** view intentional, or should `readingPaneMessages` be applied only outside Trash?
- Was `swift test` / a build run on this branch? I reviewed statically; the deleted-thread paths (`applyThreadContentChange(.threads([threadId]))` after `MailThread.deleteOne`) assume downstream handles a change notification for a now-missing thread gracefully — worth a runtime check.
- On the saveDraft-replace path (MailStore.swift:4999), the old draft row is deleted and if it was the only message the *thread is deleted locally* before the newly created server draft syncs down. Does the stand-in-based UI (compose stays open) mask that gap, or can the Drafts list flash empty?

### Suggested fixes (not applied)

- Gate `readingPaneMessages` filtering by view context (skip filtering when the thread is being viewed from Trash), or keep the filter but restore `isDraftOnly`-style handling so trashed-draft threads open *something*.
- In `removeLocalDraftMessage`, drop the `selectedThreadId = threads.first?.id` reassignment for silent callers (or only clear selection when the detail view is actually showing that thread).
- Soften/correct the comment in the `catch` of `deleteUnderlyingDraft`, or track a pending-remote-delete so sync doesn't resurrect (even a `suppressedDraftMessageIds`-style tombstone until the delete succeeds would close the loop).
- Add a GRDB-backed test for `removeLocalDraftMessage` behavior (thread deletion vs. re-derivation).

### Verdict

**SHIP** — the fix correctly addresses the reported bug through two real root causes (Discard tap stolen by the parent tap gesture, and no-op when `drafts.list` had no match), with a sensible local-first delete. The Trash-view invisibility (finding 1) and the resurrect-on-failure comment (finding 2) are real but pre-existing-adjacent edge cases that don't regress the primary flows; worth a fast-follow.
