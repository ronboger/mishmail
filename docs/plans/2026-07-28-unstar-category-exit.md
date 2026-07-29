# Plan: Category-hide unstar stickiness exits on leave-thread

**Branch:** `fix/unstar-category-exit`  
**Base:** `main` @ b251841  
**Related:** `5ff3c81` (star pin-through category hide), `5ada495` (unstar stickiness)

## Problem

After starring a non-Primary thread (Updates / Promotions / Social / Forums) so it appears under category-hide chips, unstarring keeps the row via `starStateKeepIds` until the **view or filter changes**. That is correct for continuity mid-thread, but wrong for Primary triage: an unstarred Updates newsletter can sit in the inbox for hours if the user never leaves Inbox.

Screenshot case: Existential Hope, category Updates, unstarred, hide-Updates chip on — should not be a permanent Primary resident.

## Product model

| Surface | Unstar stickiness exit |
|---------|------------------------|
| **Category hide** (inbox / account / saved views whose only star-gate is `category.hide` or legacy `excludePromotions`) | Sticky **only while the thread is selected** (or still multi-checked). Drop pin when selection leaves the thread. Archive / trash / snooze still remove immediately. |
| **Star-gated lists** (Starred mailbox, STARRED label view, `starredOnly` saved view, `is:starred` / `label:starred` search) | Keep **session stickiness** until view/filter change (current behavior). Batch triage of stars needs the longer pin. |
| **Leave-list actions** (archive, trash, spam, snooze) | Always remove; drop pin (already true). |

Star remains “pin through category hide.” Unstar means “drop pin,” not “archive.” Stickiness only prevents yank while still on the thread.

## Implementation sketch

### 1. Split the stickiness policy (not necessarily two keep-sets)

Add a pure helper (testable, hostless) e.g. in `Support/` or next to existing selection helpers:

```swift
enum StarStickinessPolicy {
    /// Session-long: Starred mailbox, is:starred, starredOnly, STARRED label.
    case session
    /// Thread-long: category hide / excludePromotions is the only star gate.
    case thread
    /// No star gate active.
    case none
}
```

Policy inputs mirror `starStateFilterActive` but distinguish:

- **session** if any of: `.starred` view, STARRED label view/chip, saved `starredOnly`, search `is:starred` / `label:starred`
- **thread** else if category hide non-empty (chips or saved-view chipsJSON) or legacy `excludePromotions`
- **none** otherwise

When both could apply (e.g. hide chips + Starred mailbox): prefer **session** — you are in a star-gated list.

Keep a single `starStateKeepIds` set. Policy only changes *when pins are dropped*, not how CategoryHide SQL widens.

### 2. Drop thread-long pins when selection leaves

In `setSelectionFocus` (or immediately after selection id changes in `selectThread`):

When policy is `.thread` and `selectedThreadId` changes from `old` → `new`:

1. For every id in `starStateKeepIds` that is **not** `new` and **not** in `checkedThreadIds`, remove from `starStateKeepIds`.
2. For each dropped id still present in `threads`, if the row no longer qualifies under category hide (unstarred + in a hidden category), optimistically remove it (reuse `applyOptimisticThreadUpdate` / leave-list path) **or** call a narrow reload. Prefer optimistic remove for snappy triage; async reload remains source of truth.
3. Do **not** auto-advance selection for these drops (user already moved selection). Only remove the row under the new focus.

Also drop non-focused pins at **pin time** for thread-long policy on bulk unstar: only pin ids that are currently selected or checked; other bulk targets unstar without stickiness (or pin then immediately drop non-selected — same end state).

### 3. Optimistic leave-list gap (optional but recommended)

Today `threadLeavesCurrentList` for `.inbox` does **not** consult category hide or `starStateKeepIds` (noted in prior Fable review as pre-existing). For leave-thread drops to feel instant without waiting for reload:

- Extend the inbox branch (or a helper used only when hide is non-empty): unstarred + matches a hidden category + id not in keepIds → leaves list.
- Mirror in unit tests (hostless), same pattern as `ThreadListOptimistic.leavesInboxList`.

Scope control: if this is risky, ship selection-drop + `reloadThreads()` only; follow up on optimistic hide. Prefer including optimistic hide so j/k after unstar does not flash-stick until reload.

### 4. Clearing sites (unchanged + one new)

Keep existing clears:

- view change, account change, `!starStateFilterActive` on reload
- drop on optimistic remove (trash/archive)

Add:

- selection leave under `.thread` policy (above)

Do **not** clear session pins on selection leave.

### 5. Tests

Extend `StarUnstarStickinessTests` / `StarredCategoryFilterTests` (hostless):

1. **Policy unit tests:** matrix of view/chips/search → session | thread | none.  
2. **Category hide:** keepIds still keep unstarred promo under hide (unchanged SQL).  
3. **Thread-long exit model (pure):** given keepIds `{A}`, selection moves A→B, policy thread → keepIds empty, A would leave list if unstarred+hidden.  
4. **Session policy:** selection move must **not** imply dropping keepIds (document as policy test; MailStore integration may remain mirrored).  
5. **Bulk unstar under thread policy:** only selected/checked ids remain in keep set.  
6. **Optimistic hide leave** (if implemented): unstarred + CATEGORY_UPDATES + hide Updates + not keep → leaves; with keep → stays.

### 6. Non-goals

- No toast / “pinned by star” chrome in this change.  
- No auto-archive on unstar.  
- No change to unread badge / SidebarCounts (starred category mail still does not inflate Primary badge).  
- No change to remote-sync unstar (still no pin; background unstar can drop on reload).

## Risks / open questions for review

1. **Browse vs open split:** during j/k, `selectedThreadId` moves before `openedThreadId` settles. Dropping pin on selection leave means the reading pane may still show a thread whose list row just vanished. Is that OK? (Likely yes — same as archive advance.) Alternative: drop only when `openedThreadId` leaves — slightly stickier during pure browse.

2. **Multi-select:** if A is selected and B,C checked, unstar all three under thread policy — pin A+B+C while checked; when uncheck B without selecting it, drop B? Propose: keep while in `checkedThreadIds` OR selected.

3. **Saved views** with both `starredOnly` and category hide → session (star-gated wins). Confirm.

4. **Is extending optimistic category-hide leave in scope** or selection-drop + reload only?

## Success criteria

- Unstar Updates pin-through in Primary+hide Updates; stay on thread → row stays.  
- Move selection to next thread → row leaves list without requiring sidebar/view change.  
- Unstar in Starred mailbox; move selection → row **stays** until leave Starred / clear filter.  
- Trash/archive of sticky row still removes.  
- `make test` green; Fable review SHIP.
