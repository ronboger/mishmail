# Customizable Shortcuts + Trash Auto-Advance + `?` Cheat Sheet — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After trashing a conversation, selection advances to the next one down; users can rebind the Gmail-style single-key shortcuts in a new Settings pane; pressing `?` shows a cheat-sheet listing all shortcuts.

**Architecture:** A new `KeyBindings` registry (in `Support/`, unit-testable) maps single keys ↔ commands with UserDefaults-persisted overrides. `MailStore.handleKey` dispatches through it instead of hardcoded `switch` cases. A new `ShortcutsSettings` pane edits bindings (refuse + warn on conflict); a new `ShortcutsHelpView` sheet lists them. Trash auto-advance is a pure helper (`Support/SelectionAdvance.swift`) called from `MailStore.trash`.

**Tech Stack:** Swift 5.10, SwiftUI + AppKit (NSEvent monitors), XCTest, xcodegen. macOS 14 deployment target.

**Spec:** `docs/superpowers/specs/2026-07-05-customizable-shortcuts-design.md`

## Global Constraints

- Test target (`PerfectMailTests` in `project.yml`) compiles listed source files directly — no app host. Any file with unit tests MUST be added to its `sources:` list and must not import SwiftUI or reference MailStore.
- Test gate: `make test` (runs xcodegen + xcodebuild test, scheme `PerfectMailTests`). Run from the repo/worktree root. Must pass before every commit (pre-commit hook runs it).
- Match existing test style: plain `import XCTest`, internal access (sources compiled into the test target — no `@testable`).
- Reserved keys, never bindable: `g` (go-to prefix) and `?` (help).
- Rebindable commands are exactly the 13 in the spec catalog. `g`-chords, arrows/Return/Esc, and ⌘-combos stay fixed.
- Conflict policy: refuse + warn (no auto-swap).
- Comment style: sparing, explains *why*, sentence-case — match surrounding code.

---

### Task 1: KeyBindings registry (Support/, unit-tested)

**Files:**
- Create: `Sources/PerfectMail/Support/KeyBindings.swift`
- Create: `Tests/PerfectMailTests/KeyBindingsTests.swift`
- Modify: `project.yml` (add `Sources/PerfectMail/Support/KeyBindings.swift` to `PerfectMailTests` target's `sources:` list, alongside the other `Support/` entries)

**Interfaces:**
- Produces (later tasks rely on these exact names):
  - `enum ShortcutCommand: String, CaseIterable, Codable` with cases `archive, trash, toggleStar, toggleRead, snooze, reply, replyAll, forward, label, undo, compose, next, prev`
  - `struct ShortcutSpec: Identifiable { let command: ShortcutCommand; let title: String; let category: KeyBindings.Category; let defaultKey: String }`
  - `@MainActor final class KeyBindings: ObservableObject` with:
    - `enum Category: String, CaseIterable { case navigation = "Navigation"; case actions = "Actions" }`
    - `static let reservedKeys: Set<String>` (= `["g", "?"]`)
    - `static let catalog: [ShortcutSpec]`
    - `@Published var capturing: Bool` (default false)
    - `init(defaults: UserDefaults = .standard)`
    - `func key(for command: ShortcutCommand) -> String`
    - `func command(for key: String) -> ShortcutCommand?`
    - `enum RebindResult: Equatable { case ok; case conflict(ShortcutCommand); case rejected(String) }`
    - `func rebind(_ command: ShortcutCommand, to key: String) -> RebindResult`
    - `func resetToDefaults()`
    - `static func title(for command: ShortcutCommand) -> String` (lookup in catalog)

- [ ] **Step 1: Write the failing tests**

`Tests/PerfectMailTests/KeyBindingsTests.swift`:

```swift
import XCTest

@MainActor
final class KeyBindingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "KeyBindingsTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultLookups() {
        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.key(for: .archive), "e")
        XCTAssertEqual(kb.key(for: .trash), "#")
        XCTAssertEqual(kb.command(for: "j"), .next)
        XCTAssertEqual(kb.command(for: "k"), .prev)
        XCTAssertNil(kb.command(for: "x"))
        XCTAssertNil(kb.command(for: "g"))  // reserved, never a command
    }

    func testCatalogCoversAllCommandsWithUniqueDefaults() {
        XCTAssertEqual(Set(KeyBindings.catalog.map(\.command)), Set(ShortcutCommand.allCases))
        let keys = KeyBindings.catalog.map(\.defaultKey)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertTrue(Set(keys).isDisjoint(with: KeyBindings.reservedKeys))
    }

    func testRebindUpdatesBothDirectionsAndPersists() {
        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.rebind(.archive, to: "x"), .ok)
        XCTAssertEqual(kb.key(for: .archive), "x")
        XCTAssertEqual(kb.command(for: "x"), .archive)
        XCTAssertNil(kb.command(for: "e"))  // old key freed
        // A fresh instance over the same defaults sees the override.
        let kb2 = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb2.key(for: .archive), "x")
    }

    func testConflictRefusedAndUnchanged() {
        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.rebind(.snooze, to: "e"), .conflict(.archive))
        XCTAssertEqual(kb.key(for: .snooze), "h")
        XCTAssertEqual(kb.command(for: "e"), .archive)
    }

    func testReservedAndInvalidRejected() {
        let kb = KeyBindings(defaults: defaults)
        guard case .rejected = kb.rebind(.archive, to: "g") else { return XCTFail("g must be rejected") }
        guard case .rejected = kb.rebind(.archive, to: "?") else { return XCTFail("? must be rejected") }
        guard case .rejected = kb.rebind(.archive, to: "ab") else { return XCTFail("multi-char must be rejected") }
        guard case .rejected = kb.rebind(.archive, to: " ") else { return XCTFail("space must be rejected") }
        XCTAssertEqual(kb.key(for: .archive), "e")
    }

    func testRebindToOwnKeyIsOk() {
        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.rebind(.archive, to: "e"), .ok)
        XCTAssertEqual(kb.key(for: .archive), "e")
    }

    func testResetToDefaults() {
        let kb = KeyBindings(defaults: defaults)
        _ = kb.rebind(.archive, to: "x")
        kb.resetToDefaults()
        XCTAssertEqual(kb.key(for: .archive), "e")
        let kb2 = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb2.key(for: .archive), "e")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test` — Expected: compile FAILURE (`KeyBindings` not found). That counts as the red step here since the type doesn't exist yet.

- [ ] **Step 3: Implement KeyBindings**

`Sources/PerfectMail/Support/KeyBindings.swift`:

```swift
import Foundation
import Combine

/// A user-rebindable single-key command (Gmail-style, no modifiers).
enum ShortcutCommand: String, CaseIterable, Codable {
    case archive, trash, toggleStar, toggleRead, snooze
    case reply, replyAll, forward, label, undo, compose
    case next, prev
}

struct ShortcutSpec: Identifiable {
    let command: ShortcutCommand
    let title: String
    let category: KeyBindings.Category
    let defaultKey: String
    var id: ShortcutCommand { command }
}

/// Single source of truth for the Gmail-style single-key shortcuts:
/// defaults, user overrides (persisted to UserDefaults), and both
/// key→command and command→key lookups. The `g` prefix and `?` help key
/// are reserved and handled before this registry is consulted.
@MainActor
final class KeyBindings: ObservableObject {
    enum Category: String, CaseIterable {
        case navigation = "Navigation"
        case actions = "Actions"
    }

    static let reservedKeys: Set<String> = ["g", "?"]

    static let catalog: [ShortcutSpec] = [
        .init(command: .next, title: "Next conversation", category: .navigation, defaultKey: "j"),
        .init(command: .prev, title: "Previous conversation", category: .navigation, defaultKey: "k"),
        .init(command: .archive, title: "Archive", category: .actions, defaultKey: "e"),
        .init(command: .trash, title: "Delete (Trash)", category: .actions, defaultKey: "#"),
        .init(command: .toggleStar, title: "Star / Unstar", category: .actions, defaultKey: "s"),
        .init(command: .toggleRead, title: "Mark read / unread", category: .actions, defaultKey: "u"),
        .init(command: .snooze, title: "Snooze", category: .actions, defaultKey: "h"),
        .init(command: .reply, title: "Reply", category: .actions, defaultKey: "r"),
        .init(command: .replyAll, title: "Reply all", category: .actions, defaultKey: "a"),
        .init(command: .forward, title: "Forward", category: .actions, defaultKey: "f"),
        .init(command: .label, title: "Label…", category: .actions, defaultKey: "l"),
        .init(command: .undo, title: "Undo", category: .actions, defaultKey: "z"),
        .init(command: .compose, title: "Compose", category: .actions, defaultKey: "c"),
    ]

    static func title(for command: ShortcutCommand) -> String {
        catalog.first { $0.command == command }!.title
    }

    enum RebindResult: Equatable {
        case ok
        case conflict(ShortcutCommand)
        case rejected(String)
    }

    /// True while the Settings pane is capturing a key press, so the main
    /// window's key monitor stands down and the capture can't fire actions.
    @Published var capturing = false

    @Published private(set) var overrides: [ShortcutCommand: String]

    private let store: UserDefaults
    private static let defaultsKey = "keyBindings"

    init(defaults: UserDefaults = .standard) {
        store = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let raw = try? JSONDecoder().decode([String: String].self, from: data) {
            overrides = raw.reduce(into: [:]) { map, entry in
                if let cmd = ShortcutCommand(rawValue: entry.key) { map[cmd] = entry.value }
            }
        } else {
            overrides = [:]
        }
    }

    func key(for command: ShortcutCommand) -> String {
        overrides[command] ?? Self.catalog.first { $0.command == command }!.defaultKey
    }

    func command(for key: String) -> ShortcutCommand? {
        Self.catalog.map(\.command).first { self.key(for: $0) == key }
    }

    func rebind(_ command: ShortcutCommand, to key: String) -> RebindResult {
        guard key.count == 1, key != " " else {
            return .rejected("Press a single character key.")
        }
        guard !Self.reservedKeys.contains(key) else {
            return .rejected("“\(key)” is reserved.")
        }
        if self.key(for: command) == key { return .ok }
        if let other = self.command(for: key) { return .conflict(other) }  // `self.` — `command` is shadowed by the parameter
        overrides[command] = key
        persist()
        return .ok
    }

    func resetToDefaults() {
        overrides = [:]
        store.removeObject(forKey: Self.defaultsKey)
    }

    private func persist() {
        let raw = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            store.set(data, forKey: Self.defaultsKey)
        }
    }
}
```

- [ ] **Step 4: Add the file to the test target**

In `project.yml`, under `PerfectMailTests:` → `sources:`, add (next to the other `Support/` entries):

```yaml
      - Sources/PerfectMail/Support/KeyBindings.swift
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `make test` — Expected: all pass, including the 7 new KeyBindings tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/PerfectMail/Support/KeyBindings.swift Tests/PerfectMailTests/KeyBindingsTests.swift project.yml
git commit -m "Shortcuts: KeyBindings registry with persisted overrides"
```

---

### Task 2: Trash auto-advance (SelectionAdvance helper + MailStore.trash)

**Files:**
- Create: `Sources/PerfectMail/Support/SelectionAdvance.swift`
- Create: `Tests/PerfectMailTests/SelectionAdvanceTests.swift`
- Modify: `project.yml` (add `Sources/PerfectMail/Support/SelectionAdvance.swift` to `PerfectMailTests` sources)
- Modify: `Sources/PerfectMail/App/MailStore.swift` — `trash(_:)` (~line 1137)

**Interfaces:**
- Produces: `enum SelectionAdvance { static func neighborId(in ids: [String], removing id: String) -> String? }`
- Consumes: `MailStore.threads`, `selectedThreadId`, `selectionViaKeyboard`, `mutateThread` (all existing).

- [ ] **Step 1: Write the failing tests**

`Tests/PerfectMailTests/SelectionAdvanceTests.swift`:

```swift
import XCTest

final class SelectionAdvanceTests: XCTestCase {
    func testMiddleRowAdvancesDown() {
        XCTAssertEqual(SelectionAdvance.neighborId(in: ["a", "b", "c"], removing: "b"), "c")
    }

    func testFirstRowAdvancesDown() {
        XCTAssertEqual(SelectionAdvance.neighborId(in: ["a", "b", "c"], removing: "a"), "b")
    }

    func testLastRowFallsBackUp() {
        XCTAssertEqual(SelectionAdvance.neighborId(in: ["a", "b", "c"], removing: "c"), "b")
    }

    func testOnlyRowReturnsNil() {
        XCTAssertNil(SelectionAdvance.neighborId(in: ["a"], removing: "a"))
    }

    func testMissingIdReturnsNil() {
        XCTAssertNil(SelectionAdvance.neighborId(in: ["a", "b"], removing: "zz"))
        XCTAssertNil(SelectionAdvance.neighborId(in: [], removing: "a"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test` — Expected: compile FAILURE (`SelectionAdvance` not found).

- [ ] **Step 3: Implement the helper**

`Sources/PerfectMail/Support/SelectionAdvance.swift`:

```swift
import Foundation

/// Which row should be selected after removing one from a list — the row
/// below it, or the one above when the removed row was last (Gmail-style
/// auto-advance after archive/trash).
enum SelectionAdvance {
    static func neighborId(in ids: [String], removing id: String) -> String? {
        guard let idx = ids.firstIndex(of: id) else { return nil }
        if idx + 1 < ids.count { return ids[idx + 1] }
        return idx > 0 ? ids[idx - 1] : nil
    }
}
```

Add to `project.yml` under `PerfectMailTests:` → `sources:`:

```yaml
      - Sources/PerfectMail/Support/SelectionAdvance.swift
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test` — Expected: all pass.

- [ ] **Step 5: Wire auto-advance into MailStore.trash**

In `Sources/PerfectMail/App/MailStore.swift`, replace the body of `trash(_:)` (currently ~line 1137, the version calling `mutateThread` + `offerUndo("Moved to Trash")`) with:

```swift
func trash(_ thread: MailThread) {
    // Gmail-style auto-advance: when the selected thread is trashed, land
    // on the next conversation down (or the one above if it was last)
    // instead of leaving nothing selected. Computed before the mutation
    // removes the row from `threads`.
    let wasSelected = selectedThreadId == thread.id
    let neighbor = SelectionAdvance.neighborId(in: threads.map(\.id), removing: thread.id)
    mutateThread(thread) { $0.inTrash = true; $0.inInbox = false } remote: { client, id in
        try await client.trashThread(id: id)
    }
    if wasSelected, let neighbor, threads.contains(where: { $0.id == neighbor }) {
        selectionViaKeyboard = true
        selectedThreadId = neighbor
    }
    offerUndo("Moved to Trash") { [weak self] in
        guard let self else { return }
        self.mutateThread(thread) { $0.inTrash = false; $0.inInbox = true } remote: { client, id in
            try await client.modifyThread(id: id, add: ["INBOX"], remove: ["TRASH"])
        }
        self.undoAction = nil
    }
}
```

(The `offerUndo` closure is byte-for-byte the existing one — do not change it. `mutateThread` calls `reloadThreads()` synchronously, so the `threads.contains` guard runs against the post-removal list; `selectionViaKeyboard` keeps the reading pane from popping open via the `onChange` in ContentView.)

- [ ] **Step 6: Run tests + build**

Run: `make test && make build` — Expected: both succeed.

- [ ] **Step 7: Commit**

```bash
git add Sources/PerfectMail/Support/SelectionAdvance.swift Tests/PerfectMailTests/SelectionAdvanceTests.swift project.yml Sources/PerfectMail/App/MailStore.swift
git commit -m "Trash: auto-advance selection to the next conversation"
```

---

### Task 3: handleKey dispatch through KeyBindings + `?` toggle + monitor guards

**Files:**
- Modify: `Sources/PerfectMail/App/MailStore.swift` — `handleKey(_:)` (~line 1000), published vars (~line 191)
- Modify: `Sources/PerfectMail/UI/ContentView.swift` — `installKeyMonitor()` (~lines 204–288)
- Modify: `Sources/PerfectMail/UI/ThreadDetailView.swift` — prev/next `.help` texts (~lines 117–124)

**Interfaces:**
- Consumes: `KeyBindings`, `ShortcutCommand` (Task 1).
- Produces: `MailStore.keyBindings: KeyBindings` (a `let`), `MailStore.showShortcutsHelp: Bool` (`@Published`), `MailStore.perform(_ command: ShortcutCommand)`. Task 4 uses `keyBindings`; Task 5 uses `showShortcutsHelp` and `keyBindings`.

- [ ] **Step 1: Add state to MailStore**

Near the other `@Published` vars (after `@Published var selectedThreadId: String?`, ~line 191):

```swift
    /// Gmail-style "?" cheat sheet.
    @Published var showShortcutsHelp = false
    /// User-rebindable single-key shortcuts (Settings → Keyboard shortcuts).
    let keyBindings = KeyBindings()
```

- [ ] **Step 2: Refactor handleKey**

Replace the current `handleKey(_:)` body (keep the `pendingGoKey` block at the top exactly as-is) — the `switch chars` becomes:

```swift
        switch chars {
        case "g": pendingGoKey = Date(); return true
        case "?": showShortcutsHelp.toggle(); return true
        default: break
        }
        guard let command = keyBindings.command(for: chars) else { return false }
        perform(command)
        return true
    }

    /// Runs a rebindable single-key command. Kept separate from handleKey so
    /// the key→command mapping is the only thing the registry owns.
    func perform(_ command: ShortcutCommand) {
        switch command {
        case .archive: selectedThread.map(archive)
        case .trash: selectedThread.map(trash)
        case .toggleStar: selectedThread.map(toggleStar)
        case .toggleRead: if let t = selectedThread { setRead(t, read: t.isUnread) }
        case .snooze: if let t = selectedThread { snooze(t, until: Self.snoozeDate(hour: 8, addDays: 1)) }
        case .next: moveSelection(1)
        case .prev: moveSelection(-1)
        case .reply: if let t = selectedThread {
                         composeRequest = ComposeRequest(replyTo: messages(inThread: t.id).last)
                     }
        case .replyAll: if let t = selectedThread {
                            composeRequest = ComposeRequest(replyTo: messages(inThread: t.id).last, replyAll: true)
                        }
        case .forward: if let t = selectedThread {
                           composeRequest = ComposeRequest(replyTo: messages(inThread: t.id).last, forward: true)
                       }
        case .label: if selectedThread != nil { labelPickerHighlight = 0; showLabelPicker = true }
        case .undo: if let undo = undoAction { undo.undo() }
        case .compose: composeRequest = ComposeRequest(replyTo: nil)
        }
    }
```

(These case bodies are the existing ones moved verbatim; the old hardcoded key cases are deleted.)

- [ ] **Step 3: Update the ContentView key monitor**

In `installKeyMonitor()`:

a) At the very top of the monitor closure, right after `guard let store else { return event }`:

```swift
            // Settings is capturing a key for rebinding — don't run shortcuts.
            if store.keyBindings.capturing { return event }
```

b) In the Esc handling area — immediately after the existing `if store.showCommandPalette, event.keyCode == 53` block, add:

```swift
            if store.showShortcutsHelp, event.keyCode == 53 {  // esc
                store.showShortcutsHelp = false
                return nil
            }
```

c) Replace the hardcoded j/k check (line ~285):

```swift
            if chars == "j" || chars == "k" { store.selectionViaKeyboard = true }
```

with:

```swift
            if let cmd = store.keyBindings.command(for: chars), cmd == .next || cmd == .prev {
                store.selectionViaKeyboard = true
            }
```

- [ ] **Step 4: Make ThreadDetailView nav hints live**

In `Sources/PerfectMail/UI/ThreadDetailView.swift` (~lines 117–124) update the two `.help` strings:

```swift
            .help("Previous thread (\(store.keyBindings.key(for: .prev)))")
```

and

```swift
            .help("Next thread (\(store.keyBindings.key(for: .next)))")
```

(If `store` isn't in scope at that exact spot, it is available as the view's `@EnvironmentObject var store: MailStore` — check the top of the struct.)

- [ ] **Step 5: Grep for other hardcoded key hints**

Run: `grep -rn '"(e)"\|(j)\|(k)\|press e\|press #' Sources/PerfectMail/UI/` — update any hint strings found to read from `store.keyBindings.key(for:)` the same way. If none, move on.

- [ ] **Step 6: Test + build**

Run: `make test && make build` — Expected: both succeed.

- [ ] **Step 7: Commit**

```bash
git add -A Sources/PerfectMail
git commit -m "Shortcuts: dispatch single-key commands through KeyBindings"
```

---

### Task 4: Settings pane "Keyboard shortcuts"

**Files:**
- Create: `Sources/PerfectMail/UI/ShortcutsSettings.swift`
- Modify: `Sources/PerfectMail/UI/SettingsView.swift` — `Pane` enum, sidebar sections, `detail` switch

**Interfaces:**
- Consumes: `KeyBindings` (Task 1), `MailStore.keyBindings` (Task 3), existing `PaneScaffold`.

- [ ] **Step 1: Add the pane to SettingsView**

In `SettingsView.Pane`: add case `shortcuts` to the enum; `title` returns `"Keyboard shortcuts"`; `icon` returns `"keyboard"`. In the sidebar `Section("App")`, add `row(.shortcuts)` after `row(.appearance)`. In `detail`, add:

```swift
        case .shortcuts: ShortcutsSettings(bindings: store.keyBindings)
```

- [ ] **Step 2: Implement ShortcutsSettings**

`Sources/PerfectMail/UI/ShortcutsSettings.swift`:

```swift
import SwiftUI

/// Settings pane: rebind the Gmail-style single-key shortcuts. Click a
/// key capsule, press the new key; conflicts are refused with a warning.
struct ShortcutsSettings: View {
    @ObservedObject var bindings: KeyBindings
    @State private var listening: ShortcutCommand?
    @State private var warning: String?
    @State private var monitor: Any?

    var body: some View {
        PaneScaffold(title: "Keyboard shortcuts",
                     subtitle: "Click a key to change it, then press the new key. Press ? in the app to see every shortcut.") {
            Form {
                ForEach(KeyBindings.Category.allCases, id: \.self) { category in
                    Section(category.rawValue) {
                        ForEach(KeyBindings.catalog.filter { $0.category == category }) { spec in
                            row(spec)
                        }
                    }
                }
                Section {
                    HStack {
                        Button("Reset to defaults") {
                            bindings.resetToDefaults()
                            warning = nil
                        }
                        Spacer()
                        if let warning {
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 12))
                                .foregroundStyle(.orange)
                        }
                    }
                } footer: {
                    Text("Single keys only — g and ? are reserved, and ⌘ shortcuts can't be changed yet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .onDisappear { stopListening() }
    }

    private func row(_ spec: ShortcutSpec) -> some View {
        LabeledContent(spec.title) {
            Button {
                if listening == spec.command { stopListening() } else { startListening(spec.command) }
            } label: {
                Text(listening == spec.command ? "Press a key…" : bindings.key(for: spec.command))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .frame(minWidth: 44)
                    .padding(.vertical, 3).padding(.horizontal, 8)
                    .background(listening == spec.command
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
        }
    }

    private func startListening(_ command: ShortcutCommand) {
        stopListening()
        listening = command
        bindings.capturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { stopListening() }
            if event.keyCode == 53 { return nil }  // esc cancels
            let mods = event.modifierFlags.intersection([.command, .option, .control])
            guard mods.isEmpty,
                  let chars = event.charactersIgnoringModifiers, !chars.isEmpty
            else {
                warning = "Only single keys without ⌘/⌥/⌃ can be used."
                return nil
            }
            switch bindings.rebind(command, to: chars) {
            case .ok:
                warning = nil
            case .conflict(let other):
                warning = "“\(chars)” is already used by \(KeyBindings.title(for: other))."
            case .rejected(let message):
                warning = message
            }
            return nil
        }
    }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        listening = nil
        bindings.capturing = false
    }
}
```

- [ ] **Step 3: Test + build**

Run: `make test && make build` — Expected: both succeed.

- [ ] **Step 4: Commit**

```bash
git add Sources/PerfectMail/UI/ShortcutsSettings.swift Sources/PerfectMail/UI/SettingsView.swift
git commit -m "Settings: Keyboard shortcuts pane with rebinding"
```

---

### Task 5: `?` cheat-sheet sheet

**Files:**
- Create: `Sources/PerfectMail/UI/ShortcutsHelpView.swift`
- Modify: `Sources/PerfectMail/UI/ContentView.swift` — add a `.sheet` presenting the help view

**Interfaces:**
- Consumes: `MailStore.showShortcutsHelp`, `MailStore.keyBindings` (Task 3), `KeyBindings.catalog` / `key(for:)` (Task 1).

- [ ] **Step 1: Implement ShortcutsHelpView**

`Sources/PerfectMail/UI/ShortcutsHelpView.swift`:

```swift
import SwiftUI

/// Gmail-style "?" cheat sheet: every shortcut, grouped, with any custom
/// bindings reflected live. Dismiss with Esc, ?, or the Done button.
struct ShortcutsHelpView: View {
    @ObservedObject var bindings: KeyBindings
    @Environment(\.dismiss) private var dismiss

    /// Fixed (non-rebindable) shortcuts, shown for reference.
    private static let fixed: [(section: String, rows: [(key: String, title: String)])] = [
        ("Go to (press g, then…)", [
            ("g i", "Inbox"), ("g s", "Starred"), ("g t", "Sent"),
            ("g d", "Drafts"), ("g a", "All mail"), ("g p", "Promotions"),
        ]),
        ("Other", [
            ("↑ / ↓", "Browse conversations"),
            ("Return", "Open conversation"),
            ("Esc", "Close reading pane / drop focus"),
            ("⌘K", "Command palette"),
            ("⌃F", "Filter menu"),
            ("⌘⇧R", "Sync all"),
            ("⌘+ / ⌘− / ⌘0", "Text size"),
            ("⌘,", "Settings"),
            ("?", "This help"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard shortcuts").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)
            Divider().padding(.horizontal, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(KeyBindings.Category.allCases, id: \.self) { category in
                        section(category.rawValue,
                                rows: KeyBindings.catalog.filter { $0.category == category }
                                    .map { (bindings.key(for: $0.command), $0.title) })
                    }
                    ForEach(Self.fixed, id: \.section) { group in
                        section(group.section, rows: group.rows)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 440, height: 520)
    }

    private func section(_ title: String, rows: [(key: String, title: String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(rows, id: \.title) { row in
                HStack {
                    Text(row.key)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .padding(.vertical, 2).padding(.horizontal, 6)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                        .frame(minWidth: 90, alignment: .leading)
                    Text(row.title).font(.system(size: 13))
                    Spacer()
                }
            }
        }
    }
}
```

- [ ] **Step 2: Present it from ContentView**

In `ContentView`'s body, alongside the existing sheet/overlay modifiers (search for `.sheet(` in the file and add next to them):

```swift
        .sheet(isPresented: $store.showShortcutsHelp) {
            ShortcutsHelpView(bindings: store.keyBindings)
        }
```

- [ ] **Step 3: Test + build**

Run: `make test && make build` — Expected: both succeed.

- [ ] **Step 4: Commit**

```bash
git add Sources/PerfectMail/UI/ShortcutsHelpView.swift Sources/PerfectMail/UI/ContentView.swift
git commit -m "Help: Gmail-style ? shortcut cheat sheet"
```

---

### Task 6: Final gate + manual smoke test

- [ ] **Step 1: Full gate**

Run: `make test && make build` — Expected: both succeed.

- [ ] **Step 2: Manual smoke test (launch the built app)**

Launch the Debug build. Verify:
1. Select a middle conversation in the inbox, press `#` → it moves to trash **and the next conversation down is selected** (reading pane state preserved).
2. Trash the **last** conversation → selection moves to the one above.
3. Press `?` → cheat sheet appears; Esc and `?` both dismiss it.
4. Settings (⌘,) → Keyboard shortcuts → rebind Archive to `x`; typing the capture key does NOT trigger a mail action; then in the main window `x` archives and `e` does nothing.
5. Rebind Snooze to `x` → refused with a "already used by Archive" warning.
6. Reset to defaults → `e` archives again; `?` sheet shows defaults.

- [ ] **Step 3: Report results**

Report each check pass/fail. Do not claim success without having observed the behavior.
