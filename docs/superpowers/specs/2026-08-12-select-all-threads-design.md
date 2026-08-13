# ⌘A select-all for the thread list

**Date:** 2026-08-12
**Status:** Proposed

## Problem

MishMail already has a full multi-select system for the thread list:
`MailStore.checkedThreadIds`, per-row checkboxes (shown on hover, when
checked, or when any row is checked), shift-click range toggling
(`toggleChecked(_:extendRange:)`), and a bulk-action bar
(`multiSelectBar`) for archive/trash/star/read/spam once one or more
threads are checked.

There is no way to select everything at once — you have to click every
checkbox (or shift-click a range) by hand. Gmail and most native Mac
list UIs bind ⌘A to "select all" for exactly this. MishMail has no ⌘A
binding today.

## Approach

Add one store method and one keyboard-chord handler; no new UI.

- `checkedThreadIds` already drives the checkbox rows and the bulk-action
  bar reactively, so populating it is the entire feature — no view
  changes needed.
- MishMail's ⌘-chords (⌘K, ⌘Z, ⌘1-9, ⌘↩) are handled by one central
  `NSEvent` local monitor in `ContentView.installKeyMonitor()`, each
  chord with its own guard clauses. ⌘A follows the same pattern rather
  than introducing a second mechanism (e.g. a SwiftUI `.keyboardShortcut`
  modifier, which would fight the existing monitor for the event).

## Scope

- **What "select all" means:** every thread currently loaded into
  `MailStore.threads` for the active view (inbox, a label, search
  results, …) — i.e. exactly what `toggleChecked`'s shift-range logic
  already treats as the list's display order (`selectionOrder`). The
  list is infinite-scroll / paginated (`loadMoreThreads`); ⌘A does
  **not** trigger loading further pages first. It selects what's on
  screen-or-scrolled-past right now, matching Gmail's basic
  checkbox-select-all (before its "select all N matching this search"
  banner). If more loads in later, those rows start unchecked like any
  newly-appeared row.
- **Repeat presses:** ⌘A always means "select all" — pressing it again
  while everything is already selected is a no-op. It is not a toggle.
  Esc already clears `checkedThreadIds` (existing Esc ladder in
  `installKeyMonitor`); that remains the only way to clear via keyboard.
- **Must not hijack text editing.** ⌘A is the OS convention for
  "select all text" in every text field MishMail has — search bar,
  compose To/Cc/Bcc/Subject/body, address chip editor, Settings text
  fields. Those must keep working exactly as they do today.

## Design

### `MailStore.checkAllVisibleThreads()`

New method, adjacent to `toggleChecked` / `clearCheckedThreads`:

```swift
/// Cmd-A: check every thread currently loaded in the list (Gmail-style
/// select-all). Does not fetch further pages — only what's already in
/// `selectionOrder`.
func checkAllVisibleThreads() {
    let order = selectionOrder
    guard !order.isEmpty else { return }
    checkedThreadIds = Set(order)
    lastCheckedThreadId = order.last
    applyThreadLongStarPinDrops(selectionIntent: nil)
}
```

`selectionOrder` (private, already exists) is `displayOrder.isEmpty ?
threads.map(\.id) : displayOrder` — the same source `toggleChecked`
uses for shift-range, so this reuses an established, tested notion of
"the list's current order" rather than inventing a new one.
`lastCheckedThreadId = order.last` keeps a subsequent shift-click
extending from a sensible anchor. `applyThreadLongStarPinDrops` is
called after every other mutation of `checkedThreadIds`; select-all
must not be an exception (skipping it would leave star-pin state
inconsistent with a normal checkbox-driven select-all).

### `ContentView.installKeyMonitor()` — new ⌘A block

Inserted alongside the other ⌘-chord blocks (after ⌘Z, before the
overlay-specific handling that follows). Guards mirror the existing
⌘Z block, minus the undo-specific text-focus bypass (⌘A has no reason
to ever act while text is focused — unlike undo, there's no "but do it
anyway" case):

```swift
// ⌘A selects every thread currently loaded in the list (Gmail-style
// select-all), mirroring the checkbox multi-select. Any editable text
// field (search, compose, address chips, Settings…) keeps the OS's
// native Select All instead — this never fires while one is focused.
if mods == .command,
   !event.modifierFlags.contains(.shift),
   event.charactersIgnoringModifiers?.lowercased() == "a",
   event.window == NSApp.mainWindow,
   !store.showCommandPalette,
   !store.showLabelPicker,
   !store.showShortcutsHelp,
   store.editingView == nil,
   ComposeKeyOwnership.allowsMailboxKeys(
       hasRequest: store.composeRequest != nil,
       minimized: store.composeMinimized,
       finishing: store.composeFinishing),
   !TextFocus.isEditing(event.window?.firstResponder) {
    store.checkAllVisibleThreads()
    return nil
}
```

Guard-by-guard rationale:

- `event.window == NSApp.mainWindow` — same pattern the search-arrows
  handling already uses; without it, ⌘A while Settings is frontmost
  would silently select-all in the (invisible) main window behind it.
- `!store.showCommandPalette / !store.showLabelPicker /
  !store.showShortcutsHelp` — these overlays own the keyboard while
  open; same guards ⌘Z already uses.
- `store.editingView == nil` — same as ⌘Z; a view-editor sheet owns
  input.
- `ComposeKeyOwnership.allowsMailboxKeys(...)` — expanded/mid-finish
  compose owns mailbox-level shortcuts; same helper every other
  mailbox-level chord in this monitor already calls.
- `!TextFocus.isEditing(event.window?.firstResponder)` — the single
  guard that actually protects native text select-all; this is the
  helper `AddressField`, the Esc ladder, and ⌘Z's bypass logic already
  use to detect "an editable text control has focus."

No changes to `selectedThreadId` or the reading pane — matching how
checkbox-driven multi-select already behaves (checking rows doesn't
touch the currently open thread).

## Testing

Add to `Tests/MishMailTests` (hostless target, no app host needed):

- `checkAllVisibleThreads()` sets `checkedThreadIds` to exactly the
  current `threads` ids.
- `lastCheckedThreadId` is set to the last id in display order after
  the call.
- Calling it again when everything is already checked is a no-op
  (idempotent — `checkedThreadIds` unchanged).
- Calling it with an empty thread list leaves `checkedThreadIds` empty
  (no crash on `order.last`).

The `ContentView` key-chord routing itself is not covered by
`MishMailTests` (none of the other chords in `installKeyMonitor` are
either — it's UI-event plumbing, not core logic); manual verification
via `make run` covers it, same as the existing chords.

## Out of scope

- Loading further pages before selecting ("select all N matching this
  view" banner, Gmail-style). Can be a follow-up if it turns out to be
  wanted — the scope question above intentionally keeps this version
  simple.
- Toggle-off-on-repeat-press. Esc already clears; no need for a second
  mechanism.
