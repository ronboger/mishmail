# Fable review — notice toast moved to bottom-leading, non-interactive

- **Date:** 2026-08-02
- **Grok job:** ship-20260802T014347-66389
- **Implementer model:** grok-4.5 (verified via `jacq-grok status`)
- **Branch:** jacq/ship-20260802T014347-66389
- **Reviewed commit:** eb5481e (0d408db rebased onto main e650ff1)
- **Verdict:** SHIP

## Problem

The transient confirmation toast (`store.notice`, e.g. "Sent" after sending an
email) shared a `.overlay(alignment: .bottom)` with the undo toast, centered at
the window bottom with 20pt padding. That is exactly where the draft card's
Continue/Discard buttons sit, so the pill overlapped them and intercepted
clicks (screenshot: "Sent" covering the Continue button).

## Change reviewed

- `ContentView.swift`: notice toast split into its own
  `.overlay(alignment: .bottomLeading)` with `.padding(.leading, 20)
  .padding(.bottom, 20)`, identical capsule styling and transition, plus
  `.allowsHitTesting(false)` so it can never block clicks. Undo toast stays
  centered and interactive (it has the Undo button).
- `ThreadListView.swift`: stale cross-reference comment updated.
- Comments updated per brief; no other files touched in the commit.

## Review notes

- Grok's sandbox blocked SPM resolution (GRDB), so it committed with
  `--no-verify`. Supervisor rebased onto main (clean) and ran `make test` in
  the worktree: **TEST SUCCEEDED** — 1197 tests, 0 failures.
- `.animation(PMMotion.feedback, value: store.notice)` is attached to the same
  parent, so the new overlay still animates — verified it remains after the
  split branches.
- Bottom-leading corner overlays only the sidebar footer area; nothing
  clickable lives there, and hit-testing is off regardless.

## Verdict

SHIP — merged to main.
