import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: MailStore
    @State private var keyMonitor: Any?

    var body: some View {
        NavigationSplitView {
            Sidebar()
        } content: {
            ThreadListView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 400)
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
            store.chips = FilterChips()
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
                if !store.syncStatus.isEmpty {
                    ProgressView().controlSize(.small)
                    Text(store.syncStatus).font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    store.composeRequest = .init(replyTo: nil)
                } label: { Label("Compose", systemImage: "square.and.pencil") }
                    .keyboardShortcut("n", modifiers: .command)
                Button {
                    Task { await store.syncAll() }
                } label: { Label("Sync", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
        .sheet(item: $store.composeRequest) { request in
            ComposeView(replyTo: request.replyTo)
        }
        .sheet(item: $store.editingView) { view in
            ViewEditor(view: view)
        }
        .overlay {
            if store.showCommandPalette {
                CommandPalette()
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
            guard mods.isEmpty,
                  !store.showCommandPalette,
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
                sidebarItem(.reminders, icon: "bell", badge: store.unreadCounts["reminders"])
                sidebarItem(.trash, icon: "trash")
            }
            ForEach(store.accounts) { account in
                Section(account.id) {
                    Label("Inbox", systemImage: "tray")
                        .tag(MailboxView.account(account.id))
                    ForEach(store.labelsByAccount[account.id] ?? []) { label in
                        Label(label.name, systemImage: "tag")
                            .tag(MailboxView.label(account: account.id,
                                                   labelId: label.gmailLabelId,
                                                   name: label.name))
                    }
                }
            }
            Section {
                Button {
                    store.addAccount()
                } label: {
                    Label("Add Google Account…", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func sidebarItem(_ view: MailboxView, icon: String, badge: Int? = nil) -> some View {
        Label(view.title, systemImage: icon)
            .badge((badge ?? 0) > 0 ? badge! : 0)
            .tag(view)
    }
}
