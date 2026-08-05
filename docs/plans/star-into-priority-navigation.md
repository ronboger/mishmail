# Starring into Priority: navigation & scroll design notes

Status as of 2026-08-04.

## Problem

With Priority split on (`PrioritySplit.Mode` starred/starredImportant),
starring the focused thread re-partitions it into the Priority section at the
top of the list. Selection tracks the thread id, so:

1. the list scrolls up to follow the row into Priority ("the view jumps"), and
2. the rebuilt `displayOrder` makes the next Down/j land on the row's new
   Priority-section neighbor (another starred thread) instead of the thread
   that sat below it in the date groups.

## What we shipped

**(a) Star-nav anchor** (`Sources/MishMail/Support/StarNavAnchor.swift`,
merged 2026-08-04, commit 750d843): starring captures a one-shot memory of the
pre-star Down/Up neighbors; the next ±1 `moveSelection` while focus is still
the starred thread jumps to the original-position neighbor, then the anchor
clears. Lazily self-invalidating (wrong focus, multi-step, missing target,
view change). Fixes (2) only. Review:
`docs/codex-reviews/2026-08-04-jacq-ship-20260804T152545-star-nav-anchor-review-1.md`.

**(b) Scroll suppression** (this change): keep the viewport where it was when
the star-triggered re-partition moves the selected row into Priority, instead
of chasing the row to the top. Fixes (1). Composes with (a) — Down still
returns to the original spot.

## The counterfactual: deferred re-partition

The alternative design considered and deliberately NOT taken (yet): don't move
the thread into Priority while it is still selected — pin it in place in its
date group, and let it migrate when the user navigates away or the list
reloads. This is the mirror image of the existing `starStateKeepIds` unstar
pins (which keep a just-unstarred thread visible in star-gated lists until the
user leaves it).

Why it lost to anchor + scroll suppression:

- **Delayed motion is a worse surprise.** The thread would teleport to the top
  on a later, unrelated action (Down, sync reload, view switch), breaking the
  cause-and-effect of "I starred it, it moved". The unstar pins get away with
  deferral because their motion is *removal from a filtered list* — never
  witnessed. This motion is a *promotion to the top of the visible list*.
- **Inconsistency window.** The list would show a starred thread outside the
  Priority section while the section claims to hold "starred".
- **Asymmetric failure modes.** A stale anchor costs one keypress landing
  where vanilla nav would have gone. A buggy pin lifecycle produces visible
  rendering bugs (threads stuck in the wrong section, jumps at odd times) —
  and would interact with the existing star/read stickiness pin systems.

## Plan, if we ever revisit

Revisit if the immediate move into Priority still feels disruptive after
living with (a)+(b). Sketch:

1. New pin set on MailStore, e.g. `justStarredHoldIds` — mirror of
   `starStateKeepIds` with inverted meaning ("render in original date group
   despite qualifying for Priority").
2. Populate in `toggleStar`/`toggleStarChecked` (star direction) under the
   same guards as `captureStarNavAnchor`.
3. `PrioritySplit.partition` (or the ThreadListView call site) treats held ids
   as non-qualifying so the row stays in its date group.
4. Drop lifecycle: clear on selection leaving the held thread (reuse the
   `StarStickiness.selectionDropsThreadPins` intent rules), on view change,
   and on reload — at which point the row migrates to Priority.
5. Retire `StarNavAnchor` and the scroll suppression — both become
   unnecessary once the row no longer moves while selected.

The cost center is step 4: a second, inverted pin lifecycle coexisting with
the unstar pins. Budget review time for interactions between the two.
