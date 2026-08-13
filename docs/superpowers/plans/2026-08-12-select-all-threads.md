# ⌘A Select-All for the Thread List Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pressing ⌘A checks every thread currently loaded in the list (Gmail-style select-all), lighting up the existing checkbox multi-select and bulk-action bar, without ever hijacking native "select all text" in any text field.

**Architecture:** A pure function (`SelectionAdvance.selectAll(order:)`) computes the new checked-set and shift-select anchor from the list's existing display order — following this codebase's established pattern of keeping list-selection logic pure and unit-testable in `Support/SelectionAdvance.swift`, with `MailStore` holding only a thin stateful wrapper. A new ⌘-chord block in `ContentView`'s existing central `NSEvent` key monitor calls that wrapper, guarded exactly like the neighboring ⌘Z/⌘K/⌘1-9 chords so it never fires while a text field, overlay, or Settings window owns the keystroke.

**Tech Stack:** Swift 5.10, SwiftUI, XCTest (hostless `MishMailTests` target — no app host, DB, or network needed for the new tests).

---

## Reference: spec

Full design and rationale: `docs/superpowers/specs/2026-08-12-select-all-threads-design.md`. Read it first if anything below is unclear on *why* — this plan covers *what* and *how*, in order.

## Repo setup (once, before Task 1)

This is a Swift/Xcode project built with `xcodegen`, not a package manager you `npm install`. Confirm your environment first:

```bash
cd /Users/joshuayang/MishMail
xcode-select -p
```

Expected: a path ending in `Xcode.app/Contents/Developer` (not `CommandLineTools`). If it prints `CommandLineTools`, stop and run `make signing-doctor` for guidance — the full Xcode IDE is required to build this project, the Command Line Tools alone are not enough.

---

### Task 1: Pure select-all logic in `SelectionAdvance`

**Files:**
- Modify: `Sources/MishMail/Support/SelectionAdvance.swift:101-108` (inside the existing `SelectionAdvance` enum, right after `rangeIds`)
- Test: `Tests/MishMailTests/SelectionAdvanceTests.swift:132-135` (right after `testRangeIdsMissingReturnsNil`, before the `// MARK: - Detail open policy` comment)

- [ ] **Step 1: Write the failing tests**

Open `Tests/MishMailTests/SelectionAdvanceTests.swift`. Find this existing code (lines 132-135):

```swift
    func testRangeIdsMissingReturnsNil() {
        XCTAssertNil(SelectionAdvance.rangeIds(in: ["a", "b"], from: "a", to: "zz"))
        XCTAssertNil(SelectionAdvance.rangeIds(in: [], from: "a", to: "b"))
    }
```

Immediately after that closing `}` (and before the blank line + `// MARK: - Detail open policy` that follows it), insert:

```swift

    // MARK: - Select all

    func testSelectAllChecksEveryIdAndAnchorsOnTheLast() {
        let result = SelectionAdvance.selectAll(order: ["a", "b", "c"])
        XCTAssertEqual(result.checked, ["a", "b", "c"])
        XCTAssertEqual(result.anchor, "c")
    }

    func testSelectAllOnEmptyOrderReturnsEmpty() {
        let result = SelectionAdvance.selectAll(order: [])
        XCTAssertEqual(result.checked, [])
        XCTAssertNil(result.anchor)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/joshuayang/MishMail
xcodegen generate
xcodebuild test -project MishMail.xcodeproj -scheme MishMailTests \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/dd.noindex \
  -only-testing:MishMailTests/SelectionAdvanceTests 2>&1 | tail -40
```

Expected: **BUILD FAILURE** — `error: type 'SelectionAdvance' has no member 'selectAll'`. This is the correct red state for Swift TDD (the test won't even compile until the function exists, so there's no separate "runs but fails" stage).

- [ ] **Step 3: Write the minimal implementation**

Open `Sources/MishMail/Support/SelectionAdvance.swift`. Find the end of `rangeIds` and the enum's closing brace (lines 101-108):

```swift
    /// Inclusive range of ids between two anchors in display order (either
    /// direction). Nil when either id is missing from `order`.
    static func rangeIds(in order: [String], from: String, to: String) -> [String]? {
        guard let a = order.firstIndex(of: from),
              let b = order.firstIndex(of: to) else { return nil }
        let lo = min(a, b)
        let hi = max(a, b)
        return Array(order[lo...hi])
    }
}
```

Insert a new function before the enum's closing `}` (i.e. right after `rangeIds`'s closing brace):

```swift
    /// Inclusive range of ids between two anchors in display order (either
    /// direction). Nil when either id is missing from `order`.
    static func rangeIds(in order: [String], from: String, to: String) -> [String]? {
        guard let a = order.firstIndex(of: from),
              let b = order.firstIndex(of: to) else { return nil }
        let lo = min(a, b)
        let hi = max(a, b)
        return Array(order[lo...hi])
    }

    /// Cmd-A "select all": every id in display order becomes checked, and
    /// the last id becomes the shift-range anchor so a following
    /// shift-click extends from a sensible point. Only ever counts ids
    /// already in `order` — never triggers loading more of a paginated
    /// list.
    static func selectAll(order: [String]) -> (checked: Set<String>, anchor: String?) {
        (Set(order), order.last)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Users/joshuayang/MishMail
xcodebuild test -project MishMail.xcodeproj -scheme MishMailTests \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/dd.noindex \
  -only-testing:MishMailTests/SelectionAdvanceTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **` and `Executed N tests, with 0 failures` in the output, including `testSelectAllChecksEveryIdAndAnchorsOnTheLast` and `testSelectAllOnEmptyOrderReturnsEmpty`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MishMail/Support/SelectionAdvance.swift Tests/MishMailTests/SelectionAdvanceTests.swift
git commit -m "$(cat <<'EOF'
feat: add SelectionAdvance.selectAll for Cmd-A select-all

EOF
)"
```

---

### Task 2: `MailStore.checkAllVisibleThreads()`

**Files:**
- Modify: `Sources/MishMail/App/MailStore.swift:1502-1504` (right after `toggleChecked`, before `toggleCheckSelected`)

No new automated test in this task: `checkAllVisibleThreads()` is a thin wrapper with no branching logic of its own (all the actual behavior is `SelectionAdvance.selectAll`, already covered in Task 1) — matching how this codebase's other thin `MailStore` wrappers over `SelectionAdvance`/`ThreadListOptimistic` (e.g. `toggleCheckSelected`) aren't separately unit tested either. `Tests/MishMailTests/` has zero tests that instantiate `MailStore` directly (it owns a live database pool and sync engines), so that's not a gap specific to this change. End-to-end behavior is verified manually in Task 5.

- [ ] **Step 1: Add the method**

Open `Sources/MishMail/App/MailStore.swift`. Find `toggleChecked` and the start of `toggleCheckSelected` (lines 1479-1508):

```swift
    /// Toggle multi-select on one thread. With `extendRange` (shift-click),
    /// checks every row between the last toggle and this id in display order.
    func toggleChecked(_ id: String, extendRange: Bool = false) {
        let order = selectionOrder
        if extendRange, let anchor = lastCheckedThreadId,
           let range = SelectionAdvance.rangeIds(in: order, from: anchor, to: id) {
            let allOn = range.allSatisfy { checkedThreadIds.contains($0) }
            if allOn {
                for rid in range { checkedThreadIds.remove(rid) }
            } else {
                for rid in range { checkedThreadIds.insert(rid) }
            }
            lastCheckedThreadId = id
            applyThreadLongStarPinDrops(selectionIntent: nil)
            return
        }
        if checkedThreadIds.contains(id) {
            checkedThreadIds.remove(id)
        } else {
            checkedThreadIds.insert(id)
        }
        lastCheckedThreadId = id
        applyThreadLongStarPinDrops(selectionIntent: nil)
    }

    /// Gmail `x`: toggle check on the focused conversation.
    func toggleCheckSelected() {
        guard let id = selectedThreadId else { return }
        toggleChecked(id)
    }
```

Insert a new method between `toggleChecked` and `toggleCheckSelected`:

```swift
    /// Toggle multi-select on one thread. With `extendRange` (shift-click),
    /// checks every row between the last toggle and this id in display order.
    func toggleChecked(_ id: String, extendRange: Bool = false) {
        let order = selectionOrder
        if extendRange, let anchor = lastCheckedThreadId,
           let range = SelectionAdvance.rangeIds(in: order, from: anchor, to: id) {
            let allOn = range.allSatisfy { checkedThreadIds.contains($0) }
            if allOn {
                for rid in range { checkedThreadIds.remove(rid) }
            } else {
                for rid in range { checkedThreadIds.insert(rid) }
            }
            lastCheckedThreadId = id
            applyThreadLongStarPinDrops(selectionIntent: nil)
            return
        }
        if checkedThreadIds.contains(id) {
            checkedThreadIds.remove(id)
        } else {
            checkedThreadIds.insert(id)
        }
        lastCheckedThreadId = id
        applyThreadLongStarPinDrops(selectionIntent: nil)
    }

    /// Cmd-A: check every thread currently loaded in the list (Gmail-style
    /// select-all). Does not fetch further pages — only what's already in
    /// `selectionOrder`.
    func checkAllVisibleThreads() {
        let order = selectionOrder
        guard !order.isEmpty else { return }
        let result = SelectionAdvance.selectAll(order: order)
        checkedThreadIds = result.checked
        lastCheckedThreadId = result.anchor
        applyThreadLongStarPinDrops(selectionIntent: nil)
    }

    /// Gmail `x`: toggle check on the focused conversation.
    func toggleCheckSelected() {
        guard let id = selectedThreadId else { return }
        toggleChecked(id)
    }
```

- [ ] **Step 2: Build to verify it compiles**

```bash
cd /Users/joshuayang/MishMail
xcodegen generate
xcodebuild build -project MishMail.xcodeproj -scheme MishMail -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/dd.noindex -quiet
```

Expected: no output, exit code 0 (a clean `xcodebuild -quiet` build prints nothing on success).

- [ ] **Step 3: Run the full test suite to make sure nothing broke**

```bash
make test
```

Expected: `** TEST SUCCEEDED **`, `Executed 1443 tests, with N tests skipped and 0 failures` (1441 existing + the 2 new ones from Task 1).

- [ ] **Step 4: Commit**

```bash
git add Sources/MishMail/App/MailStore.swift
git commit -m "$(cat <<'EOF'
feat: add MailStore.checkAllVisibleThreads

EOF
)"
```

---

### Task 3: Wire ⌘A into the key monitor

**Files:**
- Modify: `Sources/MishMail/UI/ContentView.swift:905-906` (inside `installKeyMonitor()`, right after the existing ⌘Z block, before the command-palette Esc check)

- [ ] **Step 1: Add the chord handler**

Open `Sources/MishMail/UI/ContentView.swift`. Find the end of the existing ⌘Z block and the line right after it (lines 902-906):

```swift
               ComposeKeyOwnership.undoChordBypassesTextFocus(
                        pendingSend: store.pendingSend != nil,
                        composeClaimsTyping: ComposeKeyOwnership.claimsTyping(
                            hasRequest: store.composeRequest != nil,
                            minimized: store.composeMinimized,
                            finishing: store.composeFinishing))) {
                store.perform(.undo)
                return nil
            }
            if store.showCommandPalette, event.keyCode == 53 {  // esc
```

Insert a new block between the ⌘Z block's closing `}` and the command-palette Esc check:

```swift
               ComposeKeyOwnership.undoChordBypassesTextFocus(
                        pendingSend: store.pendingSend != nil,
                        composeClaimsTyping: ComposeKeyOwnership.claimsTyping(
                            hasRequest: store.composeRequest != nil,
                            minimized: store.composeMinimized,
                            finishing: store.composeFinishing))) {
                store.perform(.undo)
                return nil
            }
            // ⌘A selects every thread currently loaded in the list (Gmail-
            // style select-all), mirroring the checkbox multi-select. Any
            // editable text field (search, compose, address chips,
            // Settings…) keeps the OS's native Select All instead — this
            // never fires while one is focused.
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
            if store.showCommandPalette, event.keyCode == 53 {  // esc
```

- [ ] **Step 2: Build to verify it compiles**

```bash
cd /Users/joshuayang/MishMail
xcodegen generate
xcodebuild build -project MishMail.xcodeproj -scheme MishMail -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/dd.noindex -quiet
```

Expected: no output, exit code 0.

- [ ] **Step 3: Run the full test suite**

```bash
make test
```

Expected: `** TEST SUCCEEDED **`, 0 failures. (No new tests here — chord routing in `installKeyMonitor` isn't covered by `MishMailTests` for any of the existing chords either; Task 5 verifies this one manually.)

- [ ] **Step 4: Commit**

```bash
git add Sources/MishMail/UI/ContentView.swift
git commit -m "$(cat <<'EOF'
feat: wire Cmd-A to select-all in the thread list

EOF
)"
```

---

### Task 4: Document the shortcut

**Files:**
- Modify: `Sources/MishMail/UI/ShortcutsHelpView.swift:24-26` (the "?" cheat-sheet's fixed-shortcuts list)
- Modify: `CHANGELOG.md:7-9` (Unreleased section)

- [ ] **Step 1: Add the row to the in-app cheat sheet**

Open `Sources/MishMail/UI/ShortcutsHelpView.swift`. Find these two existing rows (lines 24-26):

```swift
            ("x", "Select / deselect (multi-select)"),
            ("Shift-click checkbox", "Select a range"),
            ("/", "Search"),
```

Insert a new row between them:

```swift
            ("x", "Select / deselect (multi-select)"),
            ("Shift-click checkbox", "Select a range"),
            ("⌘A", "Select all (multi-select)"),
            ("/", "Search"),
```

- [ ] **Step 2: Add a CHANGELOG entry**

Open `CHANGELOG.md`. Find the top of the Unreleased section (lines 7-9):

```markdown
## [Unreleased]

### Fixed
```

Insert a new `### Added` subsection before `### Fixed`:

```markdown
## [Unreleased]

### Added
- **⌘A selects every thread currently loaded in the list** — Gmail-style
  select-all for the existing checkbox multi-select, so the bulk-action bar
  (archive/trash/star/etc.) can act on the whole list at once instead of
  clicking or shift-clicking every row by hand. Only checks what's already
  loaded (the list is infinite-scroll); scrolling in more rows afterward
  doesn't retroactively check them. Never intercepts ⌘A in a text field
  (search, compose, Settings…) — native select-all-text keeps working
  everywhere it already does.

### Fixed
```

- [ ] **Step 3: Build to verify nothing broke**

```bash
cd /Users/joshuayang/MishMail
xcodegen generate
xcodebuild build -project MishMail.xcodeproj -scheme MishMail -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/dd.noindex -quiet
```

Expected: no output, exit code 0.

- [ ] **Step 4: Commit**

```bash
git add Sources/MishMail/UI/ShortcutsHelpView.swift CHANGELOG.md
git commit -m "$(cat <<'EOF'
docs: document Cmd-A select-all in the shortcuts sheet and changelog

EOF
)"
```

---

### Task 5: Manual end-to-end verification

**Files:** none (verification only — no code changes)

The thread-list checkbox state is purely local UI state, so this does **not** require a real Google account or the OAuth setup from earlier — the built-in fictional demo inbox (`make run`) already has enough threads to verify against.

- [ ] **Step 1: Build and launch the demo inbox**

```bash
cd /Users/joshuayang/MishMail
make run
```

Expected: the MishMail Debug app opens showing the fictional demo inbox (Priority section with Dana/Priya/Marcus threads, Today/Yesterday/Last 7 days groups).

- [ ] **Step 2: Press ⌘A with the thread list focused**

Click anywhere in the thread list (not into the search field), then press **⌘A**.

Expected: every visible thread row shows a checked checkbox, and the compact multi-select bulk-action bar appears at the top of the list (archive/trash/star/etc. icons).

- [ ] **Step 3: Verify text fields are unaffected**

Click into the sidebar **Search** field, type a few characters, then press **⌘A**.

Expected: the typed text in the search field is selected (standard text select-all) — the thread list's checkboxes do **not** change, and no new checkbox states appear.

Press **Cmd-N** to open Compose, click into the body, type a line of text, then press **⌘A**.

Expected: the typed text in the compose body is selected — again, no interaction with the thread-list checkboxes underneath.

- [ ] **Step 4: Verify Esc clears the selection**

Close Compose (Esc twice: once to blur the body, once for the ladder — or just click away and reopen the thread list), click into the thread list, press **⌘A** to select all again, then press **Esc**.

Expected: all checkboxes clear and the bulk-action bar disappears (per the existing Esc ladder, which already clears `checkedThreadIds` first).

- [ ] **Step 5: Report results**

No commit for this task. If any expectation above doesn't hold, stop and fix the relevant task (1-4) before proceeding — do not mark this plan complete with a failing manual check.
