---
date: 2026-07-31 00:26
kind: self-review
target: fix/compose-delete-render-and-drop-attach vs main
verdict: SHIP
model: grok-self (no fable — user asked to review myself)
effort: low
reviewed_commit: cd6b898ce69aa53947baa1b756c03e9c4edac67e
invoked_from: /Users/ronboger/mishmail/.worktrees/compose-delete-drop
git_branch: fix/compose-delete-render-and-drop-attach
---

# Self-review: compose delete render + drag attachments

Task: (1) fix weird leftover rendering when deleting text in a draft compose body; (2) allow dragging files in as attachments. User asked for fable-iterate flow but **without calling fable** — self-review only, **wait to merge**.

## What changed

1. **Delete / ghost stale pixels** (`ComposeBodyEditor.swift`)
   - Body + scroll view now use opaque `windowBackgroundColor` + `drawsBackground = true` (matches compose card). Previous `drawsBackground = false` + custom ghost overlay left deleted glyphs and old ghost suffix painted under the caret.
   - Track `lastGhostRect`; invalidate on ghost change, selection change, text change, and programmatic rewrite.
   - Prefer `firstRect(forCharacterRange:)` for ghost caret placement (trailing-space / end-of-doc).

2. **Drag-and-drop attachments**
   - `ComposeBodyTextView` registers `.fileURL`, intercepts drops so paths are never inserted into the markdown body.
   - Compose card also has SwiftUI `.onDrop(of: [.fileURL])` for drops on header/footer/chrome.
   - Drops load bytes immediately into `restoredAttachments` (sandbox grants are transient); paperclip picker still uses powerbox URLs.
   - Pure helpers in `ComposeAttachmentDrop` (pasteboard read, path dedupe) with unit tests.

## Findings

### Low — filename-only dedupe on drops

`ingestDroppedFiles` skips when `filename` already appears on a chip. Two different files both named `report.pdf` from different folders collapse to one. Same UX as Gmail chips roughly; acceptable. Path-based dedupe only applies to the paperclip URL list via `dedupeAppend`.

### Low — large drops load into memory immediately

Sandbox forces eager `Data(contentsOf:)` on drop. Multi-GB drops could spike memory; paperclip path still defers until send/autosave. No size guard (pre-existing for forwards too).

### Info — AppKit draw path untested by design

Ghost invalidation / opaque background are visual; unit tests cover drop merge rules and pasteboard file-URL filtering only. `make test` green (1136 tests, 1 skipped).

## Test coverage

- `ComposeAttachmentDropTests`: dedupe order/path/non-file; empty + file-only pasteboard.
- Full suite: **TEST SUCCEEDED** (pre-commit + manual).

## Verdict

**SHIP** — fixes the reported delete ghosting root cause (clear background + untracked ghost overlay) and adds the requested drag-in attachments without putting paths in the body. Residual lows are product nits, not blockers.

## Not done (per user)

- Did **not** call fable / jacq-claude review
- Did **not** merge to main
- Did **not** push
