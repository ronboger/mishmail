---
date: 2026-07-31 15:38
kind: fable-rereview
target: fix/compose-delete-render-and-drop-attach vs main (pass 2)
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260731T153645-83143
reviewed_commit: db4add3f52a5da1422e2071f3ff71a98229978e2
prior_review: docs/codex-reviews/2026-07-31-1532-fable-review-compose-delete-drop-attach-review-1.md
invoked_from: /Users/ronboger/mishmail/.worktrees/compose-delete-drop
git_branch: fix/compose-delete-render-and-drop-attach
---

# Review prompt

Re-review after addressing pass-1 findings. Prior review: docs/codex-reviews/2026-07-31-1532-fable-review-compose-delete-drop-attach-review-1.md (NOT READY on M1 registerForDraggedTypes).

Addressed:
- M1: removed registerForDraggedTypes; comment explains why
- M2: Task.detached for Data(contentsOf:)
- L1/L2: mergeNewFilenames + dropStatusMessage with user feedback
- L3: indexed provider order
- L4: dropped dead width >= 0
- restoredAttachments onChange schedules autosave
- tests for merge/status helpers

Task: (1) Fix leftover/ghost rendering when deleting text in draft compose. (2) Drag files into compose as attachments without path insertion; sandbox-safe.

Check the full diff vs main, confirm prior findings closed, note any new issues. Finish with SHIP or NOT READY.

# Fable Re-Review (pass 2) — compose delete ghosting + drag attachments

model:claude-fable-5
effort:low
job:review-20260731T153645-83143
cwd:/Users/ronboger/mishmail/.worktrees/compose-delete-drop

This is a read-only review task (no implementation to plan), so here is the report directly.

# Fable Re-Review (pass 2) — compose delete ghosting + drag attachments

Scope: full `git diff main` at HEAD `db4add3`, checked against pass-1 findings in `docs/codex-reviews/2026-07-31-1532-fable-review-compose-delete-drop-attach-review-1.md`.

## Prior findings — all closed ✅

| # | Status | Evidence |
|---|--------|----------|
| M1 registerForDraggedTypes | **Closed** | Call removed; only remaining reference is the explanatory comment at `Sources/MishMail/UI/ComposeBodyEditor.swift:82-86`. `super.draggingEntered/Updated/prepare/perform` fallbacks are now live again for text/RTF/image drags. |
| M2 main-thread reads | **Closed** | `Task.detached` in `ingestDroppedFiles` (`Sources/MishMail/UI/ComposeView.swift:673`); security-scope start/stop kept around each read; results marshaled back via `MainActor.run`. `defer` inside the `for` body correctly scopes stop per-iteration. |
| L1/L2 silent dedupe/failures | **Closed** | `mergeNewFilenames` + `dropStatusMessage` (`ComposeAttachmentDrop.swift:53-94`) with "Already attached." / "Couldn't read…" / mixed-partial messages, surfaced via `error = msg` (`ComposeView.swift:705`). |
| L3 provider order | **Closed** | Indexed `slots` array preserves provider order (`ComposeAttachmentDrop.swift:110-133`); lock-guarded writes; `compactMap` on notify. |
| L4 dead `width >= 0` | **Closed** | Clause dropped; guard is now `caretRect.height > 0, let win = window` (`ComposeBodyEditor.swift:557`). |
| Open Q3 autosave on chip removal | **Closed** | `.onChange(of: restoredAttachments.map(\.filename).joined(separator: "|"))` → `scheduleAutosave()` (`ComposeView.swift:606-608`). |
| Test gaps | **Partially closed** | Merge/status helpers now well covered (`ComposeAttachmentDropTests.swift:627-667`). NSItemProvider async path and `ingestDroppedFiles` integration remain untested (acceptable — pure-logic core is extracted and tested). |

## New findings (all Low/Info — none blocking)

**L1 (new). `.onDrop` claims the drop optimistically** — `ComposeView.swift:690-693`. The closure returns true if any provider *conforms* to `.fileURL`, but the async load may yield zero valid URLs (provider hands back non-URL data). Result: drag animation shows an accepted drop with nothing attached and no status message (`ingestDroppedFiles` guards `!urls.isEmpty` and returns before any feedback). Cosmetic edge; consistent with common SwiftUI onDrop practice.

**L2 (new). `error` banner doubles as drop status** — `ComposeView.swift:705`. Duplicate/failed-read notes reuse the compose error string that elsewhere carries send/save failures (`ComposeView.swift:1602, 1985`) and is cleared on send (`:1568`). A stale "Already attached." could momentarily read as a send problem, or vice-versa a real send error could be overwritten by a later drop note. Acceptable for now; a distinct transient status field would be cleaner.

**Info. `joined(separator: "|")` onChange key can collide** — a filename containing `|` could alias two different lists (e.g. `["a|b"]` vs `["a","b"]`). Worst case is a *missed* autosave scheduling on an exotic filename; other edits will trigger it. Not worth fixing unless you want `.onChange(of: restoredAttachments.map(\.filename))` directly (arrays of `String` are `Equatable`).

**Info. Double `scheduleAutosave` per drop** — the explicit call at `ComposeView.swift:709` plus the new onChange both fire. Harmless (debounced scheduler), and the explicit call is a sensible belt-and-braces for the join-collision above.

**Info. Concurrency shape checks out** — two rapid drops each compute `existingNames` inside `MainActor.run`, so merges serialize on the main actor; no lost-update race. The detached task captures the view struct by value; `@State` writes go through shared storage — standard SwiftUI pattern.

**Info. Ghost caret via `firstRect(forCharacterRange:)`** — screen→window→view conversion is correct for the flipped text view; `window == nil` falls back to the layout-manager path. The empty-body `extraLineFragmentUsedRect` preference is an improvement over the hand-pinned origin.

## Open questions

1. Do you want drop feedback ("Already attached.") auto-dismissing? It currently persists in `error` until the next action clears it.
2. Two *distinct* files sharing a name still lose the second silently-with-message (by design after L1 pass-1) — fine, or do you eventually want name suffixing (`report-2.pdf`)?

## Suggested (optional, non-blocking) fixes

1. In `.onDrop`, surface a "Couldn't read the dropped file(s)." when the async load yields zero URLs from claimed providers.
2. Route drop status through a dedicated transient field instead of `error`.
3. Simplify the onChange key to compare `restoredAttachments.map(\.filename)` arrays directly.

## Verdict

**SHIP** — all pass-1 findings (including the M1 blocker) are verified closed with correct fixes, the new helper logic is tested, and the remaining items are minor UX polish that don't affect correctness or safety.
