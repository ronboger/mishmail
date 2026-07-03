import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: MailStore
    @State private var keyMonitor: Any?

    var body: some View {
        NavigationSplitView {
            Sidebar()
        } content: {
            ThreadListView()
                .navigationSplitViewColumnWidth(min: 420, ideal: 560)
        } detail: {
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
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search all mail")
        .onChange(of: store.searchText) { store.reloadThreads() }
        .onChange(of: store.selectedView) {
            store.selectedThreadId = nil
            store.chips = FilterChips.defaults(for: store.selectedView)
            store.reloadThreads()
        }
        .onChange(of: store.chips) { store.reloadThreads() }
        .onAppear { installKeyMonitor() }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.composeRequest = .init(replyTo: nil)
                } label: { Label("Compose", systemImage: "square.and.pencil") }
                    .keyboardShortcut("n", modifiers: .command)
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
        .animation(.easeOut(duration: 0.15), value: store.composeRequest?.id)
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
            if store.showCommandPalette, event.keyCode == 53 {  // esc
                store.showCommandPalette = false
                return nil
            }
            if store.showLabelPicker, event.keyCode == 53 {  // esc
                store.showLabelPicker = false
                return nil
            }
            guard mods.isEmpty,
                  !store.showCommandPalette,
                  !store.showLabelPicker,
                  store.composeRequest == nil,
                  store.editingView == nil,
                  !(event.window?.firstResponder is NSTextView),
                  !(event.window?.firstResponder is NSTextField),
                  let chars = event.charactersIgnoringModifiers
            else { return event }
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
            List(selection: $store.selectedView) {
                Section("Views") {
                    sidebarItem(.inbox, icon: "tray", color: .blue, badge: store.unreadCounts["inbox"])
                    sidebarItem(.promotions, icon: "tag", color: .green, badge: store.unreadCounts["promotions"])
                    sidebarItem(.social, icon: "person.2", color: .purple, badge: store.unreadCounts["social"])
                    sidebarItem(.starred, icon: "star", color: .yellow)
                    sidebarItem(.snoozed, icon: "clock", color: .teal)
                    ForEach(store.savedViews) { view in
                        Label {
                            Text(view.name)
                        } icon: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .foregroundStyle(Color.stable(for: view.name))
                        }
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
                    sidebarItem(.allMail, icon: "archivebox", color: .secondary)
                    sidebarItem(.sent, icon: "paperplane", color: .cyan)
                    sidebarItem(.drafts, icon: "doc.text", color: .secondary)
                    sidebarItem(.reminders, icon: "bell", color: .orange, badge: store.unreadCounts["reminders"])
                    sidebarItem(.trash, icon: "trash", color: .secondary)
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private func sidebarItem(_ view: MailboxView, icon: String,
                             color: Color = .accentColor, badge: Int? = nil) -> some View {
        Label {
            Text(view.title)
        } icon: {
            Image(systemName: icon).foregroundStyle(color)
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Account Labels")
                .font(.headline)
                .padding(.bottom, 10)
            Form {
                ForEach(store.accounts) { account in
                    TextField(account.id, text: .init(
                        get: { labels[account.id] ?? account.displayName },
                        set: { labels[account.id] = $0 }
                    ), prompt: Text("e.g. Personal"))
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    for (id, label) in labels { store.renameAccount(id, label: label) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        }
        .padding(16)
        .frame(width: 400)
    }
}
