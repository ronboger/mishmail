import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: MailStore
    @State private var showingCompose = false
    @State private var replyContext: Message?

    var body: some View {
        NavigationSplitView {
            Sidebar()
        } content: {
            ThreadListView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 380)
        } detail: {
            if let id = store.selectedThreadId,
               let thread = store.threads.first(where: { $0.id == id }) {
                ThreadDetailView(thread: thread, onReply: { msg in
                    replyContext = msg
                    showingCompose = true
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
            store.reloadThreads()
        }
        .toolbar {
            ToolbarItemGroup {
                if !store.syncStatus.isEmpty {
                    ProgressView().controlSize(.small)
                    Text(store.syncStatus).font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    replyContext = nil
                    showingCompose = true
                } label: { Label("Compose", systemImage: "square.and.pencil") }
                    .keyboardShortcut("n", modifiers: .command)
                Button {
                    Task { await store.syncAll() }
                } label: { Label("Sync", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
        .sheet(isPresented: $showingCompose) {
            ComposeView(replyTo: replyContext)
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
}

struct Sidebar: View {
    @EnvironmentObject var store: MailStore

    var body: some View {
        List(selection: $store.selectedView) {
            Section("Mailboxes") {
                Label("Inbox", systemImage: "tray").tag(MailboxView.inbox)
                Label("Starred", systemImage: "star").tag(MailboxView.starred)
                Label("Snoozed", systemImage: "clock").tag(MailboxView.snoozed)
                Label("Sent", systemImage: "paperplane").tag(MailboxView.sent)
                Label("Trash", systemImage: "trash").tag(MailboxView.trash)
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
}
