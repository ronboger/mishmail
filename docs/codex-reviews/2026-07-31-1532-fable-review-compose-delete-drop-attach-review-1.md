---
date: 2026-07-31 15:34
kind: fable-review
target: fix/compose-delete-render-and-drop-attach vs main
verdict: NOT READY
model: claude-fable-5
effort: low
job_id: review-20260731T153236-78789
reviewed_commit: 99656ad
invoked_from: /Users/ronboger/mishmail/.worktrees/compose-delete-drop
git_branch: fix/compose-delete-render-and-drop-attach
---

# Review prompt

Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: (1) Fix weird leftover/ghost rendering when deleting text in a draft compose body (stale glyphs / double-image under caret). (2) Allow dragging files into compose as attachments without inserting file paths into the markdown body. Sandbox-safe drop handling expected.

# Fable Review — compose delete ghosting + drag attachments (pass 1)

model:claude-fable-5
effort:low
job:review-20260731T153236-78789
cwd:/Users/ronboger/mishmail/.worktrees/compose-delete-drop

This is a review-only task (no implementation to plan), so here is the report directly.

# Review: compose delete ghosting fix + drag-in attachments

Scope reviewed: `git diff main` — `ComposeAttachmentDrop.swift` (new), `ComposeBodyEditor.swift`, `ComposeView.swift`, tests, `project.yml`.

## Findings by severity

### Medium

**M1. `registerForDraggedTypes([.fileURL])` replaces NSTextView's built-in drag registrations** — `ComposeBodyEditor.swift:87`
`NSView.registerForDraggedTypes(_:)` *replaces* the registered type set; it does not merge. `NSTextView` registers a rich set at init (strings, RTF, images, colors, etc. via `readablePasteboardTypes`). After this call the body view is only a candidate destination for file-URL drags, so the `super.draggingEntered(...)` fallbacks at `ComposeBodyEditor.swift:590-618` are mostly dead: AppKit will never route a text-only or image drag to this view in the first place. Regressions: dragging selected text into/within the compose body, dragging a URL/text snippet from another app. Notably the call is also unnecessary — NSTextView already accepts `.fileURL` (that's exactly why paths were being inserted before); the `performDragOperation` override alone achieves the interception. Suggested fix: delete the `registerForDraggedTypes` line.

**M2. Synchronous `Data(contentsOf:)` on the main thread per dropped file** — `ComposeView.swift:668-671` (`ingestDroppedFiles`)
Dropping a large file (e.g. a 300 MB video) blocks the UI for the whole read, inside `performDragOperation` for body drops. Suggested fix: load off-main (e.g. `Task.detached`) and append/`scheduleAutosave` back on main; keep the security-scope start/stop around the read.

### Low

**L1. Filename-only dedupe silently drops distinct files** — `ComposeView.swift:681-685`
Two different files both named `report.pdf` (from different folders) → second one is silently discarded, no error, no chip. Also re-dropping a file that's already a chip gives zero feedback. Path-based dedupe exists in `dedupeAppend` but isn't usable here since bytes are detached from paths; at minimum consider surfacing "already attached" feedback or suffixing the filename.

**L2. Partial read failures are silent** — `ComposeView.swift:672-676`
If 3 files are dropped and 1 fails `Data(contentsOf:)`, the user gets 2 chips and no indication one was lost. The error string only fires when *all* fail.

**L3. Provider order nondeterminism** — `ComposeAttachmentDrop.swift:49-70`
`loadItem` completions append under a lock in completion order, so a multi-file drop can attach in a different order than dragged. Cosmetic; fix by indexing results per provider.

**L4. Dead condition** — `ComposeBodyEditor.swift:539`
`caretRect.width >= 0` is always true (widths are non-negative). Presumably meant `> 0`? As written the guard only screens on `height > 0` and window presence. Harmless but confusing; the fallback branch below it is effectively unreachable except when `window == nil`.

### Info

- **Partial-rect invalidation is vestigial**: `invalidateGhostDisplay()` (`ComposeBodyEditor.swift:482-488`) always sets `needsDisplay = true` for the whole view, so the carefully tracked `lastGhostRect` inset invalidation is redundant. Full redraw per keystroke/selection change is the actual fix mechanism and is fine for a compose body, but the code implies a precision that isn't there — a comment or removing `lastGhostRect` tracking would be clearer.
- **Opaque background approach checks out**: the compose card host is `Color(nsColor: .windowBackgroundColor)` (`ContentView.swift:561`, `ComposeView.swift:934`) across floating/inline/pane/split presentations, so the editor's new opaque `windowBackgroundColor` fill matches everywhere, light and dark mode.
- **No double-ingest between body drop and card `.onDrop`**: AppKit routes the drag to the deepest registered destination (the NSTextView) so SwiftUI's ancestor `.onDrop` doesn't also fire; even if it did, the filename dedupe guards it.
- **Sandbox handling is right-shaped**: bytes are copied into `restoredAttachments` at drop time (grants are transient), while powerbox-granted `fileImporter` URLs stay as URLs — consistent with `collectAttachments()` at `ComposeView.swift:515-516`. `startAccessingSecurityScopedResource` returning false for drag-pasteboard URLs is correctly tolerated (`access` guard only gates the stop call).

## Test coverage

- Good pure-logic coverage for `dedupeAppend` and pasteboard reading (`ComposeAttachmentDropTests.swift`), and `project.yml:130` globs the Tests dir so the new file is picked up.
- **Gaps**: nothing exercises `ingestDroppedFiles` (filename dedupe, partial-failure, error message), the NSItemProvider async path, or the M1 regression (a test asserting `textView.registeredDraggedTypes` still contains string types would have caught it). Ghost-rendering fix is untestable at unit level — fair.
- I did not build/run tests (read-only session).

## Open questions

1. Is drag-of-text into the compose body a flow you care about? If yes, M1 is a hard blocker; if you never drag text, it's still worth the one-line fix since the registration is a no-op for the feature.
2. Should a same-name re-drop show feedback ("already attached") rather than silently no-op (L1)?
3. Chip removal for `restoredAttachments` (`ComposeView.swift:1053`) doesn't appear to schedule autosave (only `attachmentURLs` has an `onChange` at line 603) — pre-existing, but drops now make `restoredAttachments` a primary path, so a removed dropped attachment may reappear after restart unless another edit triggers autosave. Worth confirming.

## Suggested fixes (not applied — read-only)

1. Remove `textView.registerForDraggedTypes([.fileURL])` (`ComposeBodyEditor.swift:87`). The `draggingEntered/performDragOperation` overrides already intercept file drops.
2. Move the `Data(contentsOf:)` loop off the main thread; marshal appends back to main.
3. Change `caretRect.width >= 0` → `caretRect.width > 0` or drop the clause.
4. Add a test for `ingestDroppedFiles`-style filename dedupe (extract the merge rule into `ComposeAttachmentDrop` where it's already testable).
5. Optionally surface partial-failure and duplicate-name feedback.

## Verdict

**NOT READY** — solely on M1: `registerForDraggedTypes` replacing NSTextView's drag registrations is an unintended regression to text/image drag into the body, and the fix is deleting one line (the feature works without it). Everything else is ship-quality: the ghost-rendering fix is sound and matches the card background in all presentations, the sandbox-safe drop handling is correctly designed, and the new pure helpers are well tested. Remove that line (and ideally address M2) and this is a SHIP.
