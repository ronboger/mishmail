---
date: 2026-07-30 16:56
kind: fable-review
target: branch fix/draft-list-cue-indrafts vs main
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260730T165648-37289
reviewed_commit: 832292528b4640f399a4d4534ae42f9595bfa0cc
invoked_from: /Users/ronboger/mishmail/.worktrees/draft-list-cue-indrafts
git_branch: fix/draft-list-cue-indrafts
focus: List Draft cue still showed after discarded DRAFT+TRASH (Fund Expense / Anna)
---

# Fable Review Pass 1 — draft list cue inDrafts

**Prompt:** Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: After discarding drafts in a conversation, the thread list still showed orange 'Draft, me .. Anna' for Fund Expense / Anna because labels.contains(DRAFT) uses the historical union (includes DRAFT+TRASH). Fix should use live-draft denorm inDrafts for list cue and related affordances.

## Verbatim review

## Review: `fix/draft-list-cue-indrafts` (1 commit vs main)

**Diff scope:** `MailStore.isDraftOnly`, `ThreadListView` (context menu + `participantsText`), new `ThreadListDraftCue` helper + tests, `project.yml` registration.

### Findings by severity

**None critical/high.** The change is correct and I could not find a regression path. Evidence for the key claims:

1. **`inDrafts` denorm is the right source** — `SyncEngine.trashDraftFlags` (SyncEngine.swift:868-891) sets `inDrafts` = any message with `DRAFT` and no `TRASH`, exactly the "live draft" semantic the cue needs. The historical union deliberately keeps `DRAFT` (Database.swift:81-83), which was the bug.

2. **Freshness after local discard is handled** — `removeLocalDraftMessage` (MailStore.swift:5147-5167) re-derives the thread row via `SyncEngine.deleteLocalMessage` and swaps the updated `MailThread` into `threads`, so the cue clears immediately without waiting on history sync. `ThreadRow`'s `Equatable` (ThreadListView.swift:1360-1362) compares the full model incl. the thread, so the row re-renders.

3. **No stale `labels.contains("DRAFT")` sites remain** — the only remaining ones are per-message checks (MessageParsing.swift:458/464, ThreadDetailCache.swift:525, SyncEngine.swift:971 `isOwnOutbound`), which are correct at message granularity.

4. **Menu affordances now consistent** — `Edit Draft`/`Delete Draft` (ThreadListView.swift:446) gate on `inDrafts`, and their targets (`newestDraft` → `ForwardComposer.newestDraft`, MessageParsing.swift:492) already skip `DRAFT TRASH` rows, so the old menu was showing dead buttons; fixed.

**Low / observations:**

- **L1 — `isDraftOnly` change is a no-op hardening, not a behavior fix.** The old `allSatisfy { isLiveDraft }` already returned false for discarded `DRAFT TRASH` rows (MailStore.swift:5057-5062). Fine either way; the comment is accurate.
- **L2 — `ThreadListDraftCue.showsMarker` ignores `inTrash`.** A live draft in a trashed thread will still paint "Draft" in the Trash list. That matches prior behavior and is arguably correct (there *is* a live draft), just noting it's a semantic choice, not covered by tests.
- **L3 — Migration path v30** (Database.swift:1292-1310) already backfills `inDrafts` from per-message labels, so pre-existing Fund Expense-style rows heal on upgrade. Good — no additional migration needed for this diff.

### Test coverage

- New `ThreadListDraftCueTests` covers: discarded-only → `.none`, live multi-message → `.draftLeadingNames`, draft-only / empty-participants → `.draftOnly`, plus a full `deriveThread` fixture pinning `inDrafts == false` while the union still contains `DRAFT`. Solid — the derivation-integration test is the valuable one.
- Test target includes `Tests/MishMailTests` as a directory (project.yml:130), so the new file is picked up.
- Gap (minor): no test that `.draftLeadingNames` styling survives the `inTrash` case (see L2), and I could not run the suite in this read-only session to confirm the fixture compiles against the current `Message`/`deriveThread` signatures.

### Open questions

1. Is the Trash-list behavior in L2 (live draft in trashed thread still shows the orange cue) intended?
2. Has `swift test` / xcodebuild been run on this branch? (Not executed here — read-only.)

### Suggested fixes

None required. Optionally add one test asserting the cue behavior for `inDrafts=true, inTrash=true` to pin the L2 decision.

## Verdict: **SHIP**
