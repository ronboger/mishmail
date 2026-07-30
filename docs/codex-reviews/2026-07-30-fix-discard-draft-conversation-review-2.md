---
date: 2026-07-30 16:14
kind: fable-rereview
target: branch fix/discard-draft-conversation vs main
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260730T161452-14136
reviewed_commit: cfe729388a1eb928847dc538c445958fe9367a9d
invoked_from: /Users/ronboger/mishmail/.worktrees/discard-draft-conversation
git_branch: fix/discard-draft-conversation
focus: Re-review after pass-1 follow-ups (Trash visibility, silent selection, local-delete tests)
---

# Fable Re-review Pass 2 — discard draft conversation

**Prompt:** Re-review the complete diff after addressing pass-1 findings. Check that Trash still shows DRAFT+TRASH content, silent delete no longer yanks selection, SyncEngine.deleteLocalMessage is tested, and the original Discard-in-conversation bug remains fixed. Give findings by severity and finish with SHIP or NOT READY.

## Verbatim review

## Re-review: `fix/discard-draft-conversation` vs `main` (cfe7293)

### Pass-1 follow-ups — verified

1. **Trash shows DRAFT+TRASH content** ✅ — `ThreadDetailView.swift:198` now gates `DraftMessageCard` on `isLiveDraft`, so a DRAFT+TRASH row renders as an ordinary `MessageCard` and trashed-compose threads open with visible content. `MailStore.isDraftOnly` (`MailStore.swift:5056-5060`) no longer treats trashed drafts as a compose hop, so those threads open the reading pane instead of vanishing into compose.
2. **Silent delete no longer yanks selection** ✅ — `removeLocalDraftMessage` (`MailStore.swift:5138-5160`): silent path skips `reloadThreads()`; on `.threadDeleted` it removes only the affected row and leaves `selectedThreadId` untouched; on `.threadRederived` it in-place-replaces `threads[idx]`.
3. **`SyncEngine.deleteLocalMessage` tested** ✅ — `LocalDraftDeleteTests.swift` covers all three outcomes (`.threadDeleted`, `.threadRederived` incl. `inDrafts` denorm clearing, `.missing` no-op) against a real migrated in-memory GRDB DB. FK cascades (`Database.swift:827,1144,1195`) clean up attachments/cache rows on delete, so the raw `deleteOne` is safe.
4. **Original bug still fixed** ✅ — local row is removed *before* `drafts.list` (`MailStore.swift:5114-5121`), so a listDrafts miss (orphan, replaced, already-trashed) can no longer leave a stuck card; `remoteDraftId` is pure and tested. The tap-gesture restructure (`ThreadDetailView.swift:1210-1260`) moves Discard/Continue buttons outside the tap-to-edit hit area, fixing the stolen-tap variant.

### Findings by severity

**Low — dead code with misleading doc:** `ForwardComposer.readingPaneMessages` (`MessageParsing.swift:495-500`) has no production call site (only the test at `DraftThreadHelpersTests.swift:82` uses it). Its comment claims discarded drafts "never reappear as 'Not sent' cards" — but the actual mechanism is the `isLiveDraft` gate in the view; the filter itself was (correctly) not wired up after the pass-1 Trash finding. Either delete it + its test, or reword the comment so a future reader doesn't wire it in and re-break Trash.

**Low — discarded draft visible as ordinary message outside Trash:** if a sync brings back a `DRAFT TRASH` row into a live conversation (e.g. remote delete failed race, or discard done in Gmail web), that row renders as a regular `MessageCard` with Reply/Forward in the *inbox* reading pane too, styled like a received message. `forwardableMessages` still uses `hasDraftLabel` so it can't leak into Forward-all — content exposure is contained; this is cosmetic. Acceptable trade-off for Trash visibility, worth a note.

**Low — resurrect-on-failed-remote-delete:** acknowledged in the code comment (`MailStore.swift:5133-5136`); silent paths swallow the error entirely, so a send-replace race that fails the remote delete could quietly leave a live draft on the server. Existing behavior, non-silent path surfaces `lastError` — fine.

**Nit:** `DraftMessageCard.onHover` still pushes the pointing-hand cursor over the whole card including the buttons, though only the chrome/preview is tap-to-edit now.

### Open questions
- None blocking. (Whether `readingPaneMessages` should be deleted or kept for a future non-Trash filter is a style call.)

### Suggested fixes (not applied — read-only)
- Remove `readingPaneMessages` + `testReadingPaneHidesDiscardedDrafts`, or fix its doc comment.
- Optional: in `ThreadDetailView`, give DRAFT+TRASH rows a subtle "Discarded draft" badge when shown as MessageCard.

## Verdict: **SHIP**

All pass-1 findings addressed correctly, the original bug remains fixed, and test coverage now exercises the DB-mutation core. Remaining items are cosmetic/dead-code cleanups.
