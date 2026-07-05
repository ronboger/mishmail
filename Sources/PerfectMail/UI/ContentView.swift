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
                } detail: {
                    listColumn
                }
            } else {
                NavigationSplitView {
                    Sidebar()
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
            store.chips = FilterChips.defaults(for: store.selectedView)
            store.reloadThreads()
        }
        .onChange(of: store.chips) { store.reloadThreads() }
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
        .overlay {
            if store.showCommandPalette {
                CommandPalette()
            }
            if store.showLabelPicker {
                LabelPicker()
            }
        }
        .alert("Error", isPresented: .init(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
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
        if let id = store.selectedThreadId,
           let thread = store.threads.first(where: { $0.id == id }) {
            ThreadDetailView(thread: thread, onReply: { msg in
                store.composeRequest = .init(replyTo: msg)
            })
        } else {
            Text("Select a conversation")
                .foregroundStyle(.secondary)
        }
    }

    /// Gmail-style single-key shortcuts plus Cmd-K. Ignores events when a
    /// text field, the search bar, or a sheet has focus.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak store] event in
            guard let store else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control])
            if mods == .command, event.charactersIgnoringModifiers == "k" {
                store.showCommandPalette.toggle()
                return nil
            }
            if mods == .control, event.charactersIgnoringModifiers == "f" {
                store.showFilterMenu.toggle()
                return nil
            }
            if store.showCommandPalette, event.keyCode == 53 {  // esc
                store.showCommandPalette = false
                return nil
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
                    break
                }
            }
            // Esc: first press while typing (e.g. in search) drops focus back
            // to the list; otherwise it closes the reading pane (Notion
            // Mail-style) but KEEPS the selection, so you stay where you are.
            // Compose and the view editor keep their own Esc behavior.
            if event.keyCode == 53,
               store.composeRequest == nil, store.editingView == nil {
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
            if chars == "j" || chars == "k" { store.selectionViaKeyboard = true }
            return store.handleKey(chars) ? nil : event
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var store: MailStore

    var body: some View {
        VStack(spacing: 0) {
            AccountSwitcher()
                .padding(.horizontal, 10).padding(.vertical, 8)
            // Notion Mail-style: search right under the account name, with
            // compose next to it.
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("Search", text: $store.searchText)
                        .textFieldStyle(.plain)
                        .onSubmit {
                            // Hand focus back to the list so j/k/e/etc. work.
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            if store.selectedThreadId == nil { store.moveSelection(1) }
                        }
                    if !store.searchText.isEmpty {
                        Button {
                            store.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .help("Search all mail — from: label: has:attachment")

                Button {
                    store.composeRequest = .init(replyTo: nil)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("n", modifiers: .command)
                .help("Compose (⌘N or c)")
            }
            .padding(.horizontal, 10).padding(.bottom, 8)
            List(selection: $store.selectedView) {
                Section("Views") {
                    sidebarItem(.inbox, icon: "tray", badge: store.unreadCounts["inbox"])
                    sidebarItem(.promotions, icon: "tag", badge: store.unreadCounts["promotions"])
                    sidebarItem(.social, icon: "person.2", badge: store.unreadCounts["social"])
                    sidebarItem(.starred, icon: "star")
                    sidebarItem(.snoozed, icon: "clock")
                    ForEach(store.savedViews) { view in
                        Label(view.name, systemImage: "line.3.horizontal.decrease.circle")
                            .tag(MailboxView.saved(view.id ?? -1, view.name))
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
                    sidebarItem(.allMail, icon: "archivebox")
                    sidebarItem(.sent, icon: "paperplane")
                    sidebarItem(.drafts, icon: "doc.text")
                    // Only surfaces once something is scheduled (Gmail-style).
                    if !store.scheduledSends.isEmpty || store.selectedView == .scheduled {
                        sidebarItem(.scheduled, icon: "calendar.badge.clock",
                                    badge: store.scheduledSends.count)
                    }
                    sidebarItem(.reminders, icon: "bell", badge: store.unreadCounts["reminders"])
                    sidebarItem(.trash, icon: "trash")
                }
            }
            .listStyle(.sidebar)

            // Settings pinned at the bottom (also Cmd-, from anywhere).
            Divider()
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
    }

    @ViewBuilder
    private func sidebarItem(_ view: MailboxView, icon: String, badge: Int? = nil) -> some View {
        Label(view.title, systemImage: icon)
        .badge((badge ?? 0) > 0 ? badge! : 0)
        .tag(view)
    }
}

/// Notion Mail-style account scope switcher: unified, or one account only.
/// Accounts carry user-defined labels ("Personal", "Fund", …).
struct AccountSwitcher: View {
    @EnvironmentObject var store: MailStore

    var body: some View {
        Menu {
            Button {
                store.setActiveAccount(nil)
            } label: {
                if store.activeAccountId == nil { Image(systemName: "checkmark") }
                Text("All accounts")
            }
            Divider()
            ForEach(store.accounts) { account in
                Button {
                    store.setActiveAccount(account.id)
                } label: {
                    if store.activeAccountId == account.id { Image(systemName: "checkmark") }
                    Text(menuTitle(account))
                }
            }
            Divider()
            Button("Add Google Account…") { store.addAccount() }
            Button("Edit Account Labels…") { store.editingAccountLabels = true }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .sheet(isPresented: $store.editingAccountLabels) {
            AccountLabelsEditor()
        }
    }

    private func menuTitle(_ account: Account) -> String {
        account.displayName == account.id ? account.id : "\(account.displayName) — \(account.id)"
    }

    private var title: String {
        if let active = store.activeAccountId,
           let account = store.accounts.first(where: { $0.id == active }) {
            return account.displayName
        }
        return "All accounts"
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
                        ), prompt: Text("e.g. Ron Boger"))
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
