# Design: Trash auto-advance + customizable keyboard shortcuts + `?` cheat sheet

Date: 2026-07-05
Status: Approved (pending spec review)

## Motivation

Three related keyboard/selection improvements for PerfectMail:

1. **Trash auto-advance** — Moving a conversation to trash currently leaves nothing
   selected (the thread disappears from the list and SwiftUI clears the selection).
   Instead, selection should land on the next conversation down so the user stays in
   flow.
2. **Customizable shortcuts** — Users can rebind the Gmail-style single-key commands
   from a new Settings pane, persisted across launches.
3. **`?` cheat sheet** — Pressing `?` (Gmail-style) shows a native sheet listing all
   shortcuts, reflecting any custom bindings.

## Scope

- Rebindable: the flat single-key commands only.
- Not rebindable in v1 (shown in the cheat sheet as reference): the `g`-then-key view
  navigation chords, arrows/Return/Esc, and ⌘-combinations (⌘K, ⌘⇧R, ⌘±/0, ⌘,). This
  avoids conflict detection against macOS menu equivalents for the first version.
- No new shortcuts beyond what Gmail already has (dropped the earlier "open" idea).

## Part 1 — Trash auto-advance

**File:** `Sources/PerfectMail/App/MailStore.swift`, `trash(_:)` (~line 1137).

Behavior: before mutating, compute the neighbor to advance to — the thread immediately
**below** the trashed one; if it is the last row, fall back to the thread **above**.
After `mutateThread` (which calls `reloadThreads()` synchronously), set
`selectedThreadId` to that neighbor's id if it still exists in the reloaded list; set
`selectionViaKeyboard = true` so the change is treated as keyboard browsing (no
draft-open / pane-reopen side effects from the `onChange` in `ContentView`). If the list
is now empty, leave selection cleared as today.

Applies **everywhere** trash is invoked (the `#` shortcut, command palette, context
menu) since the logic lives in `trash()` itself.

Implementation sketch:

```swift
func trash(_ thread: MailThread) {
    let neighborId = neighborAfterRemoving(thread.id)   // below, else above
    mutateThread(thread) { $0.inTrash = true; $0.inInbox = false } remote: { client, id in
        try await client.trashThread(id: id)
    }
    if let neighborId, threads.contains(where: { $0.id == neighborId }) {
        selectionViaKeyboard = true
        selectedThreadId = neighborId
    }
    offerUndo("Moved to Trash") { /* unchanged */ }
}

private func neighborAfterRemoving(_ id: String) -> String? {
    guard let idx = threads.firstIndex(where: { $0.id == id }) else { return nil }
    if idx + 1 < threads.count { return threads[idx + 1].id }   // below
    if idx - 1 >= 0            { return threads[idx - 1].id }   // above (was last)
    return nil
}
```

Note: `neighborAfterRemoving` reads `threads` *before* the mutation removes the row, so
the returned id is a still-valid sibling. `mutateThread`'s `reloadThreads()` runs
synchronously, so the `threads.contains` guard after it reflects the post-removal list.

## Part 2 — Central shortcut registry

New type `KeyBindings` (an `@MainActor ObservableObject`), owned by `MailStore` as a
`@Published` property (or nested observable). Responsibilities:

- **Command catalog** — a static ordered list of rebindable commands. Each command:
  - `id: ShortcutCommand` (a `String`-backed `enum`, stable identifier used as the
    persistence key)
  - `title: String` (human label for the UI/cheat sheet)
  - `category: Category` (`.navigation` or `.actions`)
  - `defaultKey: String` (single character)
- **Overrides** — `[ShortcutCommand: String]` (commandID → key) persisted to
  `UserDefaults` under a single JSON-encoded key (e.g. `keyBindings`). Merged over the
  defaults at launch to produce the effective binding map.
- **Lookups**:
  - `key(for: ShortcutCommand) -> String` — effective binding (override or default).
  - `command(for key: String) -> ShortcutCommand?` — reverse map used by `handleKey`.
- **Mutation** — `rebind(_ command:, to key:) -> RebindResult` where `RebindResult` is
  `.ok` or `.conflict(ShortcutCommand)`. On success, updates the map and persists. On
  conflict (the key is already bound to a different command), returns `.conflict` and
  makes **no** change.
- `resetToDefaults()` — clears overrides and persists.

### Rebindable command catalog (13)

| id           | title              | category    | default |
|--------------|--------------------|-------------|---------|
| archive      | Archive            | Actions     | `e`     |
| trash        | Delete (Trash)     | Actions     | `#`     |
| toggleStar   | Star / Unstar      | Actions     | `s`     |
| toggleRead   | Mark read / unread | Actions     | `u`     |
| snooze       | Snooze             | Actions     | `h`     |
| reply        | Reply              | Actions     | `r`     |
| replyAll     | Reply all          | Actions     | `a`     |
| forward      | Forward            | Actions     | `f`     |
| label        | Label…             | Actions     | `l`     |
| undo         | Undo               | Actions     | `z`     |
| compose      | Compose            | Actions     | `c`     |
| next         | Next conversation  | Navigation  | `j`     |
| prev         | Previous conv.     | Navigation  | `k`     |

### `handleKey` refactor

**File:** `Sources/PerfectMail/App/MailStore.swift`, `handleKey(_:)` (~line 1000).

The `g`-prefix chained navigation block at the top is unchanged. The main `switch chars`
over hardcoded letters is replaced by:

```swift
// after the g-prefix block
if chars == "g" { pendingGoKey = Date(); return true }
if chars == "?" { showShortcutsHelp.toggle(); return true }  // Part 4
guard let command = keyBindings.command(for: chars) else { return false }
perform(command)
return true
```

`perform(_ command: ShortcutCommand)` holds the existing action bodies (the current
`case` contents) in a switch keyed by command id. This keeps all action logic in
`MailStore`; only the *key → command* indirection is new.

Edge cases preserved:
- `g` stays a reserved prefix key (not in the catalog), handled before the lookup.
- Default `#`/`s`/`a` still map to their commands; since `g`-prefix consumes the
  chorded `s`/`a`/etc. first, no regression.

## Part 3 — Settings pane "Keyboard shortcuts"

**File:** `Sources/PerfectMail/UI/SettingsView.swift`.

- Add `.shortcuts` to `SettingsView.Pane` (title "Keyboard shortcuts", icon
  `keyboard`), listed under the "App" section.
- `detail` renders a new `ShortcutsSettings` view inside `PaneScaffold(title:
  "Keyboard shortcuts")`.
- Layout: a table grouped by category. Each row: command title on the left, a
  key-capture control on the right showing the current key. Clicking the control puts
  it into "listening" state; the next key press attempts a rebind via
  `keyBindings.rebind(_:to:)`.
- **Conflict:** on `.conflict(other)`, do not change the binding; show an inline
  warning near the row, e.g. "`h` is already used by Snooze." The warning clears on the
  next successful rebind or when the user cancels.
- A "Reset to defaults" button calls `resetToDefaults()`.
- Persistence is immediate (handled inside `KeyBindings`).

Key capture: a small NSView-backed control (or a focusable SwiftUI view using
`.onKeyPress` / an `NSEvent` monitor scoped to the listening state) that reports the
pressed character. Only single-character, non-modifier keys are accepted; ⌘/⌥/⌃ combos
and multi-char keys are rejected with a brief hint.

## Part 4 — `?` cheat-sheet overlay

- New `@Published var showShortcutsHelp = false` on `MailStore`.
- `?` (shift + `/`) reaches `handleKey` as the character `"?"` (shift-only passes the
  existing `mods.isEmpty` guard in the `ContentView` key monitor). `handleKey` toggles
  `showShortcutsHelp` (toggling, so a second `?` closes it).
- A `.sheet(isPresented:)` in `ContentView` presents `ShortcutsHelpView`: a scrollable,
  categorized list. Sections: Navigation, Actions (rebindable, showing effective keys
  from `keyBindings`), and a "Other" reference section listing the fixed shortcuts
  (`g i/s/t/d/a/p`, arrows, Return, Esc, ⌘K, ⌘⇧R, ⌘±/0, ⌘,).
- Dismiss with Esc (add a case to the `ContentView` monitor, or rely on the sheet's
  default) or by pressing `?` again.

## Data flow

```
UserDefaults ──load──▶ KeyBindings (defaults ⊕ overrides)
                          ▲   │
              rebind()    │   │ command(for:key)
   ShortcutsSettings ─────┘   ▼
                        MailStore.handleKey ──▶ perform(command)
                          │
   ShortcutsHelpView ◀────┘ (reads key(for:) for display)
```

## Testing

- **KeyBindings unit tests:** default lookups; override persistence round-trip through
  UserDefaults; `command(for:)` reverse lookup; `rebind` success updates both
  directions; `rebind` conflict returns `.conflict` and mutates nothing;
  `resetToDefaults` restores defaults and clears storage.
- **Trash auto-advance:** with a mock/in-memory `threads` list — trashing a middle row
  selects the row below; trashing the last row selects the previous; trashing the only
  row clears selection. (Exercise `neighborAfterRemoving` directly where full store
  wiring is heavy.)
- **handleKey dispatch:** a custom binding (e.g. archive → `x`) causes `x` to archive
  and `e` to no-op; `?` sets `showShortcutsHelp`.
- Manual: rebind in Settings, confirm conflict warning, confirm `?` sheet reflects the
  custom binding, confirm reset.

## Out of scope (v1)

- Rebinding `g`-prefix chords, arrows/Return/Esc, and ⌘-combinations.
- Auto-swap on conflict (we refuse + warn).
- Per-account or per-view bindings.
- Import/export of binding sets.
