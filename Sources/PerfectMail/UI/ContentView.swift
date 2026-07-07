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
                        .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 400)
                } detail: {
                    listColumn
                }
            } else {
                NavigationSplitView {
                    Sidebar()
                        .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 400)
                } content: {
                    listColumn
                        .navigationSplitViewColumnWidth(min: 420, ideal: 560)
                } detail: {
                    detailPane
                }
            }
        }
        // Search lives in the sidebar (Notion Mail-style), not the toolbar.
        .onChange(of: store.searchText) { store.reloadThreads() }
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
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
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
            SnoozeSheet { store.snooze(thread, until: $0) }
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
                LabelPicker()
            }
        }
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
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.4)))
                .shadow(radius: 10)
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
                switch event.keyCode {
                case 53:  // esc
                    store.showLabelPicker = false
                    return nil
                case 125:  // down — picker clamps to the filtered list
                    store.labelPickerHighlight += 1
                    return nil
                case 126:  // up
                    store.labelPickerHighlight = max(store.labelPickerHighlight - 1, 0)
                    return nil
                default:
                    // If the picker's text field hasn't grabbed focus yet (it
                    // can lose the race right after opening), typed characters
                    // would fall through to the thread list's type-select.
                    // Route them into the filter query instead.
                    if mods.isEmpty, !(event.window?.firstResponder is NSTextView) {
                        if event.keyCode == 51 {  // delete
                            if !store.labelPickerQuery.isEmpty { store.labelPickerQuery.removeLast() }
                        } else if let chars = event.charactersIgnoringModifiers, !chars.isEmpty,
                                  !chars.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                            store.labelPickerQuery += chars
                        }
                        return nil
                    }
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
            SearchField(prompt: "Search", text: $store.searchText, onSubmit: {
                // Hand focus back to the list so j/k/e/etc. work.
                NSApp.keyWindow?.makeFirstResponder(nil)
                if store.selectedThreadId == nil { store.moveSelection(1) }
            })
            .help("Search — from: to: subject: label: has:attachment is:unread is:starred after: before:")
            .padding(.horizontal, 10).padding(.bottom, 8)
            List(selection: $store.selectedView) {
                Section("Views") {
                    sidebarItem(.inbox, badge: store.unreadCounts["inbox"])
                    sidebarItem(.promotions, badge: store.unreadCounts["promotions"])
                    sidebarItem(.social, badge: store.unreadCounts["social"])
                    sidebarItem(.starred)
                    sidebarItem(.snoozed)
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
                .help("Download PerfectMail \(release.version) from GitHub")
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
