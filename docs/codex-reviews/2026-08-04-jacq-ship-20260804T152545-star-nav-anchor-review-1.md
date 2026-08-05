---
date: 2026-08-04 17:10
kind: fable-iterate review
implementer: grok-4.5 (jacq-grok ship)
grok_job_id: ship-20260804T152545-25716
branch: jacq/ship-20260804T152545-25716
reviewed_commit: 750d843a332cd40a46eab0e265aef5f0e834f03b
verdict: SHIP
---

# Review: keep Down/Up anchored to original list position after starring into Priority

## Problem
With Priority split on, starring the focused thread re-partitions it into the
Priority section at the top of the list. Selection tracks the thread id, so the
list scrolls up and `displayOrder` rebuilds; the next Down/j lands on the
starred thread's new neighbor inside the Priority section (another starred
thread) instead of the thread that sat below it in the date groups.

## Change (diff vs main: 4 files, +254)
- `Sources/MishMail/Support/StarNavAnchor.swift` (new): pure hostless helper.
  `anchor(displayOrder:focusId:starredIds:)` captures pre-star next/prev
  neighbors, skipping co-starred ids; `applies(...)` gates consumption to ±1
  moves while focus is still the starred thread and the target still exists;
  `targetId(in:delta:)` picks the side.
- `MailStore.swift`: `starNavAnchor` stored one-shot; captured in
  `toggleStar`/`toggleStarChecked` (star direction only, inbox + priority mode
  active + focused row among targets + not already in Priority section);
  consumed at the top of `moveSelection` before normal navigation; cleared on
  view change and lazily on any non-applying move. Deliberately NOT cleared in
  `updateDisplayOrder` or `reloadThreads` (the star schedules a reconciliation
  reload ~140ms later that must not wipe the anchor).
- `project.yml`: StarNavAnchor.swift added to the MishMailTests target sources
  (hostless tests compile Support files directly).
- `Tests/MishMailTests/StarNavAnchorTests.swift`: 12 tests — mid/top/bottom
  neighbors, adjacent-starred skip, all-starred nil neighbors, missing focus,
  applies rejections (wrong focus, multi-step, missing target), targetId sides.

## Review notes
- Guard chain in `captureStarNavAnchor` correctly excludes: non-inbox views,
  priority off, star toggled on a non-focused row (icon click on another row),
  and rows already in the Priority section (no re-partition happens).
- `.vips` mode: anchor is still captured though starring does not move the row;
  benign — nextId equals the natural next row, behavior identical.
- One-shot clear-always semantics: a non-applying first move (e.g. Up at top of
  list with prevId nil) drops the anchor and falls through to normal nav.
  Acceptable; matches "one press restores your place".
- Unstar path (`advanceForPriorityUnstar`, star stickiness pins) untouched.

## Verification
- `make test` in the worktree: **1303 tests, 0 failures** (5 skipped).
- `-only-testing:MishMailTests/StarNavAnchorTests`: **12/12 passed**.
- Grok ran with sandboxed package resolution blocked; commit was made with
  `--no-verify` in the worktree — full suite re-run here (supervisor) passed.

## Verdict
SHIP.
