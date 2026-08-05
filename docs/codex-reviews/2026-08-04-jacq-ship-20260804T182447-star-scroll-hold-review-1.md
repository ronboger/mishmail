---
date: 2026-08-04 18:35
kind: fable-iterate review
implementer: grok-4.5 (jacq-grok ship)
grok_job_id: ship-20260804T182447-57122
branch: jacq/ship-20260804T182447-57122
reviewed_commit: aa83965cbf3da8106cd7f230962a7421c4f4e7f0
verdict: SHIP (visual verification pending — see notes)
---

# Review: hold viewport in place when starring moves the row into Priority

Companion to the star-nav anchor fix (750d843). Fixes the remaining half of
the complaint: the list scroll-jumping to the Priority section when the
selected row is starred into it.

## Diagnosis (Grok, confirmed plausible from code)
The jump is AppKit follow-selection: macOS `List(selection:)` is
NSTableView-backed and keeps the selected row visible when its index changes
across a data update. No app code scrolls the thread list today.

## Change (diff vs main: 4 files, +146/−17)
- `StarNavAnchor`: `holdId(from:)` = `nextId ?? prevId` (the pre-star neighbor
  that does not move); `shouldRestoreScrollHold(...)` pure gate — hold row
  exists and survives the regroup, selection is still the starred thread,
  selection actually landed in Priority, hold ≠ selected.
- `MailStore`: `starScrollHoldId` one-shot, set in `captureStarNavAnchor`
  (same guards as the keyboard anchor), cleared on view change and in
  `moveSelection` alongside the anchor; consumed only via
  `consumeStarScrollHold()` so the view never mutates store state ad hoc.
- `ThreadListView`: `ScrollViewReader` wraps the List; rows get `.id(thread.id)`
  (required for `scrollTo`); after the regroup that consumes a pending hold,
  a next-runloop `proxy.scrollTo(holdId, anchor: nil)` inside a
  no-animation `Transaction` counters the system's follow-selection jump.
- Tests: +6 in `StarNavAnchorTests` (hold id preference, restore gating).

## Review notes
- Counter-scroll (not prevention) was the right call: decoupling the selection
  binding or NSTableView introspection risks the selection highlight and
  normal scroll-follow. Worst-case failure here is a benign extra minimal
  scroll.
- `anchor: nil` = minimal scroll to reveal. Restoration is approximate (the
  hold row lands at the nearest viewport edge rather than its exact prior
  offset), but it keeps the user in their date group instead of at the top.
- `.id(thread.id)` duplicates the ForEach identity, so no diffing change is
  expected; this is the one piece that wants eyes on the running app.
- Hold lifecycle is strictly narrower than the anchor's (cleared everywhere
  the anchor is, plus consumed on first regroup) — no leak path found.

## Verification
- Full suite in the worktree: **1309 tests, 0 failures** (5 skipped), incl.
  6 new StarNavAnchor hold tests. (Grok's sandbox blocked package resolution;
  suite re-run by supervisor.)
- Visual check of the scroll behavior NOT completed: computer-use was held by
  another Claude session and the real MishMail inbox was on screen, so no
  keystrokes were injected. Ron should confirm in normal use: with Priority
  split on, starring a mid-list thread should leave the viewport in place
  (thread still moves to Priority; Down still returns to the original spot).

## Verdict
SHIP.
