import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: MailStore
    @State private var keyMonitor: Any?
    // Persisted so the layout survives relaunch, like the sidebar state.
    @AppStorage("readingPaneHidden") private var readingPaneHidden = false

    var body: some View {
        Group {
            if readingPaneHidden {
                // Two columns: the thread list takes the full right side.
                NavigationSplitView {
                    Sidebar()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 400)
                } detail: {
                    listColumn
                }
            } else {
                NavigationSplitView {
                    Sidebar()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 400)
                } content: {
                    listColumn
                        .navigationSplitViewColumnWidth(min: 420, ideal: 560)
                } detail: {
                    detailPane
                }
            }
        }
        // Search lives in the sidebar (Notion Mail-style), not the toolbar.
        // Typing only feeds the dropdown preview; the list follows
        // committedSearch. Clearing the field also clears an active search.
        .onChange(of: store.searchText) {
            if store.searchText.isEmpty, !store.committedSearch.isEmpty {
                store.committedSearch = ""
                store.reloadThreads()
            }
        }
        // A clicked (not keyboard-browsed) selection reopens the reading pane.
        // Clicking a pure draft skips the pane entirely and hops straight
        // into compose at the bottom (Notion Mail-style).
        .onChange(of: store.selectedThreadId) {
            defer { store.selectionViaKeyboard = false }
            guard store.selectedThreadId != nil else { return }
            if !store.selectionViaKeyboard {
                if let thread = store.selectedThread, store.isDraftOnly(thread) {
                    store.editDraft(inThread: thread)
                    store.selectedThreadId = nil
                    return
                }
                readingPaneHidden = false
            }
        }
        .onChange(of: store.selectedView) {
            store.selectedThreadId = nil
            store.resetChips()
            store.reloadThreads()
        }
        .onChange(of: store.chips) { store.reloadThreadsDebounced() }
        .onAppear {
            installKeyMonitor()
            // Don't let the sidebar search field start with keyboard focus —
            // it would swallow Esc/j/k until clicked away.
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    readingPaneHidden.toggle()
                } label: {
                    Label(readingPaneHidden ? "Show Reading Pane" : "Hide Reading Pane",
                          systemImage: "sidebar.trailing")
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .help(readingPaneHidden ? "Show the reading pane (⌥⌘0)"
                                        : "Hide the reading pane (⌥⌘0)")
            }
        }
        // Compose docks bottom-right like Gmail/Notion; the rest of the app
        // stays fully usable behind it.
        .overlay(alignment: .bottomTrailing) {
            if let request = store.composeRequest {
                ComposeView(request: request)
                    .id(request.id)
                    .frame(width: 620, height: 500)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: PMRadius.lg))
                    .pmCardElevation(cornerRadius: PMRadius.lg, intense: true)
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // A touch of spring makes the draft→compose hop legible.
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: store.composeRequest?.id)
        // Undo/notice toast: centered on the bottom of the whole window.
        .overlay(alignment: .bottom) {
            if let undo = store.undoAction {
                HStack(spacing: 14) {
                    Text(undo.label)
                        .font(.system(size: 14, weight: .medium))
                    Button("Undo") { undo.undo() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut("z", modifiers: .command)
                }
                .padding(.horizontal, 22).padding(.vertical, 13)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 10)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let notice = store.notice {
                Text(notice)
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 22).padding(.vertical, 13)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 10)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: store.undoAction?.id)
        .animation(.easeOut(duration: 0.15), value: store.notice)
        .sheet(item: $store.editingView) { view in
            ViewEditor(view: view)
        }
        .sheet(item: $store.snoozingThread) { thread in
            SnoozeSheet(current: thread.snoozeUntil) { store.snooze(thread, until: $0) }
        }
        .alert(
            "Delete this draft?",
            isPresented: Binding(
                get: { store.confirmingDraftDelete != nil },
                set: { if !$0 { store.confirmingDraftDelete = nil } }
            ),
            presenting: store.confirmingDraftDelete
        ) { thread in
            Button("Delete", role: .destructive) { store.deleteDraft(inThread: thread) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This can't be undone.")
        }
        .sheet(isPresented: $store.showShortcutsHelp) {
            ShortcutsHelpView(bindings: store.keyBindings)
        }
        .sheet(isPresented: $store.showLabelOrganizer) {
            LabelOrganizer()
        }
        .overlay {
            if store.showCommandPalette {
                CommandPalette()
            }
            if store.showLabelPicker {
                LabelPicker(picker: store.labelPicker)
            }
        }
        // Wide command-K-style search panel, floated at the window level so it
        // spills over the message list (not confined to the sidebar column).
        .overlay(alignment: .topLeading) {
            if store.searchActive {
                SearchResultsPanel()
                    .frame(width: 600, alignment: .leading)
                    .padding(.leading, 10)
                    .padding(.top, 76)
                    // Snappy fade in place — no slide-in; this app is fast.
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.06), value: store.searchActive)
        // Non-modal error banner (a background sync hiccup shouldn't interrupt
        // you). Sits above the undo/notice toast; stays until dismissed.
        .overlay(alignment: .bottom) {
            if let error = store.lastError {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 13))
                        .lineLimit(3)
                        .frame(maxWidth: 360, alignment: .leading)
                    Button("Sync") {
                        store.lastError = nil
                        Task { await store.syncAll() }
                    }
                    .buttonStyle(.borderless)
                    Button {
                        store.lastError = nil
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                            .pmHitTarget(extra: 8)
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: PMRadius.md + 2))
                .overlay(RoundedRectangle(cornerRadius: PMRadius.md + 2).strokeBorder(.orange.opacity(0.4)))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                .padding(.bottom, 76)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: store.lastError)
        // First-run: guide the Google setup instead of dead-ending on an empty
        // inbox. Disappears the moment an account connects.
        .overlay {
            if store.accounts.isEmpty {
                OnboardingView()
            }
        }
    }

    @ViewBuilder
    private var listColumn: some View {
        if store.selectedView == .scheduled {
            ScheduledListView()
        } else {
            ThreadListView()
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        Group {
            if let id = store.selectedThreadId,
               let thread = store.threads.first(where: { $0.id == id }) {
                ThreadDetailView(thread: thread, onReply: { msg in
                    store.composeRequest = .init(replyTo: msg)
                })
            } else {
                Text("Select a conversation")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(.secondary)
            }
        }
        .background(Color.notionContent)
    }

    /// Gmail-style single-key shortcuts plus Cmd-K. Ignores events when a
    /// text field, the search bar, or a sheet has focus.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak store] event in
            guard let store else { return event }
            // Settings is capturing a key for rebinding — don't run shortcuts.
            if store.keyBindings.capturing { return event }
            // The snooze sheet runs its own monitor (↑/↓/Return/Esc while
            // typing a date) — everything must pass through untouched.
            if store.snoozingThread != nil { return event }
            // Compose is open and the user is typing: every chord belongs to
            // the text system / compose handlers (⌘K insert-link, ⌃F/⌃K caret
            // motion, ⌘-digits, …), not to app-level shortcuts. Compose's own
            // monitor turns ⌘K into a hyperlink sheet; SwiftUI .keyboardShortcut
            // sends (⌘Return) and snippets (⌘/) still resolve before us.
            if store.composeRequest != nil, event.window?.firstResponder is NSText {
                return event
            }
            let mods = event.modifierFlags.intersection([.command, .option, .control])
            if mods == .command, event.charactersIgnoringModifiers == "k" {
                store.showCommandPalette.toggle()
                return nil
            }
            // ⌘1 = All accounts, ⌘2… = individual accounts, in popover order
            // (Notion Mail-style inbox switching).
            if mods == .command, let chars = event.charactersIgnoringModifiers,
               chars.count == 1, let digit = Int(chars), (1...9).contains(digit) {
                if digit == 1 {
                    store.setActiveAccount(nil)
                    return nil
                }
                let index = digit - 2
                if index < store.accounts.count {
                    store.setActiveAccount(store.accounts[index].id)
                    return nil
                }
                return event
            }
            if mods == .control, event.charactersIgnoringModifiers == "f" {
                store.showFilterMenu.toggle()
                return nil
            }
            if store.showCommandPalette, event.keyCode == 53 {  // esc
                store.showCommandPalette = false
                return nil
            }
            if store.showShortcutsHelp, event.keyCode == 53 {  // esc
                store.showShortcutsHelp = false
                return nil
            }
            // While the help sheet is up, ? still closes it, but no other bare
            // key may fall through to mail actions on the background selection.
            if store.showShortcutsHelp {
                if event.charactersIgnoringModifiers == "?" {
                    store.showShortcutsHelp = false
                    return nil
                }
                return event
            }
            if store.showLabelPicker {
                let picker = store.labelPicker
                switch event.keyCode {
                case 53:  // esc
                    store.showLabelPicker = false
                    return nil
                case 125:  // down — picker clamps to the filtered list
                    picker.highlight += 1
                    picker.navigated = true
                    return nil
                case 126:  // up
                    picker.highlight = max(picker.highlight - 1, 0)
                    picker.navigated = true
                    return nil
                case 36, 76:  // return / keypad enter: toggle (or create)
                    // Handled here, not by the text field's onSubmit — before
                    // the field wins focus, Return would otherwise be eaten
                    // by the default branch below (it's a control character,
                    // so it neither deletes nor appends).
                    if let thread = store.selectedThread {
                        let labels = store.labelPickerLabels(for: thread)
                        let createName = store.labelPickerCreateName(for: thread)
                        let rowCount = labels.count + (createName != nil ? 1 : 0)
                        let idx = min(picker.highlight, max(rowCount - 1, 0))
                        if let label = labels[safe: idx] {
                            store.toggleLabel(thread, labelId: label.gmailLabelId)
                        } else if let createName {
                            store.createLabelAndApply(name: createName, thread: thread)
                        }
                    }
                    return nil
                case 49 where picker.navigated:  // space after arrows: toggle
                    if let thread = store.selectedThread {
                        let labels = store.labelPickerLabels(for: thread)
                        let createName = store.labelPickerCreateName(for: thread)
                        let rowCount = labels.count + (createName != nil ? 1 : 0)
                        let idx = min(picker.highlight, max(rowCount - 1, 0))
                        if let label = labels[safe: idx] {
                            store.toggleLabel(thread, labelId: label.gmailLabelId)
                        } else if let createName {
                            store.createLabelAndApply(name: createName, thread: thread)
                        }
                    }
                    return nil
                default:
                    // If the picker's text field hasn't grabbed focus yet (it
                    // can lose the race right after opening), typed characters
                    // would fall through to the thread list's type-select.
                    // Route them into the filter query instead.
                    if mods.isEmpty, !(event.window?.firstResponder is NSTextView) {
                        if event.keyCode == 51 {  // delete
                            if !picker.query.isEmpty { picker.query.removeLast() }
                        } else if let chars = event.charactersIgnoringModifiers, !chars.isEmpty,
                                  !chars.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                            picker.query += chars
                        }
                        return nil
                    }
                }
            }
            // Search dropdown open: ↑/↓/Enter drive the panel directly, so
            // `/` → arrows → Enter works without ever leaving the keyboard.
            // Intercepted here so the text field never sees them. Main window
            // only — Settings keeps its own arrows/Enter even while the
            // sidebar field technically still holds main-window focus.
            if store.searchActive, mods.isEmpty, event.window == NSApp.mainWindow {
                switch event.keyCode {
                case 125:  // down — panel clamps to its rows
                    store.searchHighlight += 1
                    return nil
                case 126:  // up
                    store.searchHighlight = max(store.searchHighlight - 1, 0)
                    return nil
                case 36:   // return — run the highlighted row
                    store.searchActivateToken += 1
                    return nil
                default:
                    break
                }
            }
            // Esc: first press while typing (e.g. in search) drops focus back
            // to the list; otherwise it closes the reading pane (Notion
            // Mail-style) but KEEPS the selection, so you stay where you are.
            // Compose and the view editor keep their own Esc behavior.
            if event.keyCode == 53,
               store.composeRequest == nil, store.editingView == nil {
                // The global monitor also fires for the Settings window. There,
                // Esc should close Settings and return to the mailbox — not
                // toggle the main window's reading pane. Drop text-field focus
                // first so an in-progress edit commits before the window closes.
                if let window = event.window,
                   window.identifier?.rawValue.contains("Settings") == true {
                    if window.firstResponder is NSTextView
                        || window.firstResponder is NSTextField {
                        window.makeFirstResponder(nil)
                        return nil
                    }
                    window.close()
                    return nil
                }
                if event.window?.firstResponder is NSTextView
                    || event.window?.firstResponder is NSTextField {
                    event.window?.makeFirstResponder(nil)
                    return nil
                }
                // Next Esc drops an active search back to the plain inbox
                // (so from the search field, Esc-Esc gets you home).
                if !store.committedSearch.isEmpty || !store.searchText.isEmpty {
                    store.clearSearch()
                    return nil
                }
                if !readingPaneHidden {
                    readingPaneHidden = true
                    return nil
                }
            }
            guard mods.isEmpty,
                  !store.showCommandPalette,
                  !store.showLabelPicker,
                  store.composeRequest == nil,
                  store.editingView == nil,
                  !(event.window?.firstResponder is NSTextView),
                  !(event.window?.firstResponder is NSTextField)
            else { return event }
            // Gmail's `/`: jump focus to the sidebar search field.
            if event.charactersIgnoringModifiers == "/" {
                store.focusSearch()
                return nil
            }
            // Arrow keys browse the list without opening the pane; Enter
            // (or a click) opens the selected thread.
            switch event.keyCode {
            case 125:  // down
                store.selectionViaKeyboard = true
                store.moveSelection(1)
                return nil
            case 126:  // up
                store.selectionViaKeyboard = true
                store.moveSelection(-1)
                return nil
            case 36:   // return
                if let thread = store.selectedThread {
                    if store.isDraftOnly(thread) {
                        store.editDraft(inThread: thread)
                        store.selectedThreadId = nil
                    } else {
                        readingPaneHidden = false
                    }
                }
                return nil
            default:
                break
            }
            guard let chars = event.charactersIgnoringModifiers else { return event }
            if let cmd = store.keyBindings.command(for: chars), cmd == .next || cmd == .prev {
                store.selectionViaKeyboard = true
            }
            return store.handleKey(chars) ? nil : event
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var store: MailStore
    @ObservedObject private var updates = UpdateChecker.shared
    // Driven by `/` (Gmail-style) via store.searchFocusToken.
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Notion Mail-style header: account (avatar, name, address) with
            // compose right next to it, search on its own row below.
            HStack(spacing: 6) {
                AccountSwitcher()
                Button {
                    store.composeRequest = .init(replyTo: nil)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("n", modifiers: .command)
                .help("Compose (⌘N or \(store.keyBindings.key(for: .compose)))")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            SearchField(prompt: "Search", text: $store.searchText, focused: $searchFocused,
                        emphasized: searchFocused, onSubmit: {
                    // Fallback path — with the dropdown open, Enter is handled
                    // by the key monitor and routed to the panel instead.
                    store.commitSearch(store.searchText)
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    if store.selectedThreadId == nil { store.moveSelection(1) }
                })
                .help("Search — from: to: subject: label: has:attachment is:unread is:starred after: before:")
                .padding(.horizontal, 10).padding(.bottom, 8)
                // Gmail's `/`: focus search.
                .onChange(of: store.searchFocusToken) { searchFocused = true }
                // Drive the window-level results panel from the field's focus.
                .onChange(of: searchFocused) { store.searchActive = searchFocused }
            List(selection: $store.selectedView) {
                Section("Views") {
                    sidebarItem(.inbox, badge: store.unreadCounts["inbox"])
                    sidebarItem(.promotions, badge: store.unreadCounts["promotions"])
                    sidebarItem(.social, badge: store.unreadCounts["social"])
                    sidebarItem(.starred, badge: store.unreadCounts["starred"])
                    sidebarItem(.snoozed, badge: store.unreadCounts["snoozed"])
                    sidebarItem(.labels)
                    ForEach(store.savedViews) { view in
                        sidebarItem(.saved(view.id ?? -1, view.name))
                            .contextMenu {
                                Button("Edit View…") { store.editingView = view }
                                Button("Delete View", role: .destructive) { store.deleteView(view) }
                            }
                    }
                    Button {
                        store.editingView = SavedView.empty()
                    } label: {
                        Label("Add view", systemImage: "plus")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Section("Mail") {
                    sidebarItem(.allMail)
                    sidebarItem(.sent)
                    sidebarItem(.drafts)
                    // Only surfaces once something is scheduled (Gmail-style).
                    if !store.scheduledSends.isEmpty || store.selectedView == .scheduled {
                        sidebarItem(.scheduled, badge: store.scheduledSends.count)
                    }
                    sidebarItem(.reminders, badge: store.unreadCounts["reminders"])
                    sidebarItem(.trash)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            // Settings pinned at the bottom (also Cmd-, from anywhere).
            Divider()
            if let release = updates.available {
                Button {
                    updates.openUpdate()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                        Text("Update app to \(release.version)")
                            .font(.system(size: 12.5, weight: .medium))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12).padding(.top, 8)
                .help("Download MishMail \(release.version) from GitHub")
            }
            SettingsLink {
                HStack(spacing: 7) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                    Text("Settings")
                        .font(.system(size: 12.5))
                    Spacer()
                    Text("⌘,")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .help("Settings (⌘,)")
        }
        .background(Color.notionSidebar)
    }


    /// Notion Mail-style row: each view keeps its own icon color.
    @ViewBuilder
    private func sidebarItem(_ view: MailboxView, badge: Int? = nil) -> some View {
        Label {
            Text(view.title)
        } icon: {
            Image(systemName: view.icon)
                .foregroundStyle(view.iconColor)
        }
        .badge((badge ?? 0) > 0 ? badge! : 0)
        .tag(view)
    }
}


/// Measures the panel's natural content height so the floating panel can hug
/// its rows (instead of ScrollView greedily claiming its full max height and
/// leaving dead space below the last row).
private struct SearchPanelContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Wide command-K-style search results panel. Floats at the window level (see
/// ContentView) so it can be much wider than the sidebar, spilling over the
/// message list like Notion Mail. Shows recent searches when the query is
/// empty; otherwise a "View all results" row plus Contacts and Threads.
/// ↑/↓/Enter come in from the global key monitor via searchHighlight /
/// searchActivateToken, so the flow is fully keyboard-driven after `/`.
struct SearchResultsPanel: View {
    @EnvironmentObject var store: MailStore
    // Live thread matches; refreshed as the query changes.
    @State private var threadPreview: [MailThread] = []
    // Natural content height, so the panel caps+scrolls at 460 but otherwise
    // shrinks to fit. Defaults to the cap so the first frame isn't collapsed.
    @State private var contentHeight: CGFloat = 460
    // Debounced, off-main FTS lookup for the live preview.
    @State private var previewTask: Task<Void, Never>?

    /// Everything the highlight can land on, in display order.
    private enum Row {
        case viewAll
        case contact(MailStore.Contact)
        case thread(MailThread)
        case recent(String)
    }

    private var trimmedSearch: String {
        store.searchText.trimmingCharacters(in: .whitespaces)
    }

    private var visibleRecentSearches: [String] {
        guard !trimmedSearch.isEmpty else { return store.recentSearches }
        return store.recentSearches.filter {
            $0.range(of: trimmedSearch, options: .caseInsensitive) != nil
                && $0.caseInsensitiveCompare(trimmedSearch) != .orderedSame
        }
    }

    private var contactMatches: [MailStore.Contact] {
        trimmedSearch.isEmpty ? [] : store.contactSuggestions(for: trimmedSearch)
    }

    /// Contacts shown in the panel: matches while typing, top senders when the
    /// query is empty (so `/` opens a full panel immediately, Notion-style).
    private var shownContacts: [MailStore.Contact] {
        trimmedSearch.isEmpty ? Array(store.contacts.prefix(3)) : contactMatches
    }

    private var rows: [Row] {
        let base = trimmedSearch.isEmpty
            ? visibleRecentSearches.map { Row.recent($0) }
            : [Row.viewAll]
        return base
            + shownContacts.map { .contact($0) }
            + threadPreview.map { .thread($0) }
    }

    /// Index where the Contacts section starts (recents or view-all precede it).
    private var contactsStart: Int {
        trimmedSearch.isEmpty ? visibleRecentSearches.count : 1
    }

    /// The store's raw highlight, clamped to what's actually on screen.
    private var highlight: Int { min(store.searchHighlight, max(rows.count - 1, 0)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if trimmedSearch.isEmpty {
                            recentsSection
                        } else {
                            viewAllResultsRow(index: 0).id(0)
                        }
                        if !shownContacts.isEmpty {
                            sectionHeader("Contacts")
                            ForEach(Array(shownContacts.enumerated()), id: \.element.id) { i, contact in
                                contactRow(contact, index: contactsStart + i).id(contactsStart + i)
                            }
                        }
                        if !threadPreview.isEmpty {
                            sectionHeader("Threads")
                            ForEach(Array(threadPreview.enumerated()), id: \.element.id) { i, thread in
                                threadRow(thread, index: contactsStart + shownContacts.count + i)
                                    .id(contactsStart + shownContacts.count + i)
                            }
                        }
                        if !trimmedSearch.isEmpty, shownContacts.isEmpty, threadPreview.isEmpty {
                            Text("No contacts or threads match")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                                .padding(.horizontal, 12).padding(.vertical, 10)
                        }
                    }
                    .padding(.vertical, 5)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: SearchPanelContentHeightKey.self,
                                               value: geo.size.height)
                    })
                }
                // Hug the content, but cap (and scroll) at 460.
                .frame(height: min(contentHeight, 460))
                .onPreferenceChange(SearchPanelContentHeightKey.self) { contentHeight = $0 }
                // Keyboard highlight: clamp over-scrolled ↓ presses back to the
                // last row (like LabelPicker) and keep the row visible.
                .onChange(of: store.searchHighlight) {
                    if store.searchHighlight >= rows.count {
                        store.searchHighlight = max(rows.count - 1, 0)
                    }
                    proxy.scrollTo(highlight)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: PMRadius.md + 2))
        .pmCardElevation(cornerRadius: PMRadius.md + 2, intense: true)
        .onAppear {
            store.searchHighlight = 0
            refreshThreadPreview()
        }
        .onDisappear { previewTask?.cancel() }
        .onChange(of: store.searchText) {
            store.searchHighlight = 0
            refreshThreadPreview()
        }
        // The empty-query "latest threads" must track the list (it can reload
        // right after ✕ clears a committed search, in either observer order).
        .onChange(of: store.threads) { if trimmedSearch.isEmpty { refreshThreadPreview() } }
        // Enter from the key monitor: run whatever is highlighted.
        .onChange(of: store.searchActivateToken) { activate(rows[safe: highlight]) }
    }

    private func activate(_ row: Row?) {
        switch row {
        case .viewAll:
            runFullSearch(store.searchText)
        case .contact(let contact):
            runFullSearch("from:\(contact.email)")
        case .thread(let thread):
            openThread(thread)
        case .recent(let query):
            runFullSearch(query)
        case nil:
            // Nothing to act on (e.g. empty recents) — just close the panel.
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func rowBackground(_ index: Int) -> some View {
        (index == highlight ? Color.notionAccent.opacity(0.18) : Color.clear)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold)).kerning(0.4)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 3)
    }

    private func viewAllResultsRow(index: Int) -> some View {
        Button { runFullSearch(store.searchText) } label: {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).frame(width: 20)
                Text("View all results")
                Text("\u{201C}\(trimmedSearch)\u{201D}")
                    .foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "return").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .font(.system(size: 13.5))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowBackground(index))
        .onHover { if $0 { store.searchHighlight = index } }
    }

    private func contactRow(_ contact: MailStore.Contact, index: Int) -> some View {
        Button {
            // Notion Mail-style: jump to everything from this person.
            runFullSearch("from:\(contact.email)")
        } label: {
            HStack(spacing: 9) {
                avatar(for: contact.name.isEmpty ? contact.email : contact.name)
                VStack(alignment: .leading, spacing: 1) {
                    Text(contact.name.isEmpty ? contact.email : contact.name)
                        .font(.system(size: 13)).lineLimit(1)
                    if !contact.name.isEmpty {
                        Text(contact.email)
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowBackground(index))
        .onHover { if $0 { store.searchHighlight = index } }
    }

    private func threadRow(_ thread: MailThread, index: Int) -> some View {
        Button { openThread(thread) } label: {
            HStack(spacing: 9) {
                Image(systemName: "envelope")
                    .font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                        .font(.system(size: 13, weight: thread.isUnread ? .semibold : .regular))
                        .lineLimit(1)
                    Text(thread.participants.isEmpty ? thread.snippet : thread.participants)
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowBackground(index))
        .onHover { if $0 { store.searchHighlight = index } }
    }

    private func avatar(for label: String) -> some View {
        let initial = label.first.map { String($0).uppercased() } ?? "?"
        return Circle()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: 24, height: 24)
            .overlay(Text(initial).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary))
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if visibleRecentSearches.isEmpty {
                // Nothing yet — the Contacts/Threads sections below still fill
                // the panel, so no placeholder needed beyond a search hint.
                Text("Search — from: to: subject: label: is:unread …")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                HStack {
                    Text("RECENT SEARCHES")
                        .font(.system(size: 10, weight: .semibold)).kerning(0.4)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { store.clearRecentSearches() }
                        .buttonStyle(.plain).font(.system(size: 11))
                        .foregroundStyle(.secondary).help("Clear search history")
                }
                .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 3)
                ForEach(Array(visibleRecentSearches.enumerated()), id: \.element) { i, query in
                    Button { runFullSearch(query) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 20)
                            Text(query).font(.system(size: 13)).lineLimit(1)
                            Spacer(minLength: 4)
                            Button { store.removeRecentSearch(query) } label: {
                                Image(systemName: "xmark").font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain).help("Remove from history")
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(rowBackground(i))
                    .onHover { if $0 { store.searchHighlight = i } }
                    .id(i)
                }
                .padding(.bottom, 5)
            }
        }
    }

    private func openThread(_ thread: MailThread) {
        // Commit the query so the list shows the matching results, then select
        // this thread within them (falling back to All Mail if it's not there).
        if !trimmedSearch.isEmpty { store.commitSearch(trimmedSearch) }
        store.openThread(id: thread.id)
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// Commit the search to the thread list and hand focus back to it.
    private func runFullSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        store.commitSearch(q)
        NSApp.keyWindow?.makeFirstResponder(nil)
        if store.selectedThreadId == nil { store.moveSelection(1) }
    }

    private func refreshThreadPreview() {
        previewTask?.cancel()
        let q = trimmedSearch
        // Empty query: latest threads from the current list, so `/` opens a
        // full panel right away — instant, straight from memory.
        if q.isEmpty {
            threadPreview = Array(store.threads.prefix(4))
            return
        }
        // Typing: debounce, then run the FTS lookup off the main thread. Keep
        // the current rows visible until the new ones arrive so there's no
        // flicker between keystrokes.
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let matches = await store.threadSuggestions(for: q)
            guard !Task.isCancelled else { return }
            threadPreview = matches
        }
    }
}

/// Notion Mail-style account scope switcher: unified, or one account only.
/// Accounts carry user-defined labels ("Personal", "Fund", …).
/// A Button + popover, NOT a Menu: macOS flattens custom views in Menu
/// labels, which drops the avatar and name entirely.
struct AccountSwitcher: View {
    @EnvironmentObject var store: MailStore
    @State private var showMenu = false

    var body: some View {
        Button {
            showMenu = true
        } label: {
            HStack(spacing: 8) {
                if let account = activeAccount {
                    avatar(for: displayTitle(account), key: account.id, size: 28)
                } else {
                    allInboxesIcon(size: 28)
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 3) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if let account = activeAccount, let label = labelText(account) {
                            labelPill(label, account: account)
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                accountRow(nil, shortcut: 1)
                ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                    accountRow(account, shortcut: index + 2)
                }
                Divider().padding(.vertical, 4)
                FilterMenuRow(icon: "plus", title: "Add Google Account…") {
                    showMenu = false
                    store.addAccount()
                }
                FilterMenuRow(icon: "pencil", title: "Edit Account Labels…") {
                    showMenu = false
                    store.editingAccountLabels = true
                }
            }
            .padding(8)
            .frame(width: 280)
        }
        .sheet(isPresented: $store.editingAccountLabels) {
            AccountLabelsEditor()
        }
    }

    /// One row of the account popover: avatar, name + address, checkmark.
    /// `shortcut` is the ⌘-digit that switches to this scope from anywhere.
    private func accountRow(_ account: Account?, shortcut: Int? = nil) -> some View {
        let selected = store.activeAccountId == account?.id
        return Button {
            store.setActiveAccount(account?.id)
            showMenu = false
        } label: {
            HStack(spacing: 8) {
                if let account {
                    avatar(for: displayTitle(account), key: account.id, size: 24)
                } else {
                    allInboxesIcon(size: 24)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(account.map(displayTitle) ?? "All accounts")
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Text(account?.id ?? "\(store.accounts.count) inboxes")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let account, let label = labelText(account) {
                    labelPill(label, account: account)
                }
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.notionAccent)
                }
                if let shortcut, shortcut <= 9 {
                    Text("⌘\(shortcut)")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTint()
    }

    /// Stacked-trays icon for the unified "All accounts" scope.
    private func allInboxesIcon(size: CGFloat) -> some View {
        Image(systemName: "tray.2.fill")
            .font(.system(size: size * 0.54)).foregroundStyle(.secondary)
            .frame(width: size, height: size)
    }

    /// Colored circle with the first initial, Notion Mail-style.
    private func avatar(for name: String, key: String, size: CGFloat) -> some View {
        Circle()
            .fill(Color.stable(for: key))
            .frame(width: size, height: size)
            .overlay {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }

    private var activeAccount: Account? {
        store.activeAccountId.flatMap { id in store.accounts.first { $0.id == id } }
    }

    /// Full name first, like Notion Mail's account header: the outgoing
    /// sender name if set, then the local label, then the address.
    private func displayTitle(_ account: Account) -> String {
        if !account.senderName.isEmpty { return account.senderName }
        return account.displayName
    }

    /// The local label, when it adds information beyond the title/address.
    /// Rendered as a tinted pill next to the name, never as part of it.
    private func labelText(_ account: Account) -> String? {
        guard !account.senderName.isEmpty else { return nil }
        let label = account.displayName
        guard !label.isEmpty, label != account.id, label != account.senderName else { return nil }
        return label
    }

    /// Small capsule tinted with the account's avatar color ("Fund", "Personal").
    private func labelPill(_ label: String, account: Account) -> some View {
        let tint = Color.stable(for: account.id)
        return Text(label)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .fixedSize()
    }

    private var title: String {
        activeAccount.map(displayTitle) ?? "All accounts"
    }

    private var subtitle: String {
        store.activeAccountId ?? "\(store.accounts.count) inboxes"
    }
}

/// Rename accounts ("Personal", "Fund", …); labels are local only.
struct AccountLabelsEditor: View {
    @EnvironmentObject var store: MailStore
    @Environment(\.dismiss) private var dismiss
    @State private var labels: [String: String] = [:]
    @State private var senderNames: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Accounts")
                .font(.headline)
                .padding(.bottom, 10)
            Form {
                ForEach(store.accounts) { account in
                    Section(account.id) {
                        TextField("Label (only you see this)", text: .init(
                            get: { labels[account.id] ?? account.displayName },
                            set: { labels[account.id] = $0 }
                        ), prompt: Text("e.g. Personal"))
                        TextField("Send as (recipients see this)", text: .init(
                            get: { senderNames[account.id] ?? account.senderName },
                            set: { senderNames[account.id] = $0 }
                        ), prompt: Text("e.g. Jane Doe"))
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    for (id, label) in labels { store.renameAccount(id, label: label) }
                    for (id, name) in senderNames { store.setSenderName(id, name: name) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        }
        .padding(16)
        .frame(width: 420)
    }
}
