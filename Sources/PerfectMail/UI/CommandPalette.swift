import SwiftUI

/// Cmd-K palette: jump to views, compose, sync.
struct CommandPalette: View {
    @EnvironmentObject var store: MailStore
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    struct Command: Identifiable {
        let id: String
        let title: String
        let icon: String
        let action: (MailStore) -> Void
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .onTapGesture { store.showCommandPalette = false }

            VStack(spacing: 0) {
                TextField("Search mail (from: label: has:attachment) or type a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .padding(14)
                    .focused($focused)
                    .onSubmit { run(filtered[safe: highlighted]) }
                    .onChange(of: query) { highlighted = 0 }
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, cmd in
                            HStack {
                                Image(systemName: cmd.icon).frame(width: 20)
                                Text(cmd.title)
                                Spacer()
                            }
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(idx == highlighted ? Color.notionAccent.opacity(0.2) : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture { run(cmd) }
                            .onHover { if $0 { highlighted = idx } }
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .frame(width: 480)
            .shadow(radius: 24)
            .padding(.top, 120)
            .onAppear {
                // Focus reliably once the overlay is in the hierarchy.
                focused = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { focused = true }
            }
            .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, filtered.count - 1); return .handled }
            .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
        }
    }

    private var commands: [Command] {
        var cmds: [Command] = [
            Command(id: "compose", title: "Compose New Message", icon: "square.and.pencil") {
                $0.composeRequest = .init(replyTo: nil)
            },
            Command(id: "sync", title: "Sync All Accounts", icon: "arrow.clockwise") { s in
                Task { await s.syncAll() }
            },
            Command(id: "newview", title: "Add View…", icon: "plus") {
                $0.editingView = SavedView.empty()
            },
        ]
        let builtins: [MailboxView] = [.inbox, .promotions, .social, .starred, .snoozed,
                                       .reminders, .drafts, .sent, .allMail, .trash]
        for v in builtins {
            cmds.append(Command(id: "view.\(v.title)", title: "Go to \(v.title)", icon: "tray") { s in
                s.selectedView = v
            })
        }
        for v in store.savedViews {
            cmds.append(Command(id: "saved.\(v.id ?? -1)", title: "Go to \(v.name)",
                                icon: "line.3.horizontal.decrease.circle") { s in
                s.selectedView = .saved(v.id ?? -1, v.name)
            })
        }
        return cmds
    }

    private var filtered: [Command] {
        let raw = query.trimmingCharacters(in: .whitespaces)
        let q = raw.lowercased()
        guard !q.isEmpty else { return commands }
        // Search is always the first, default action for any typed text.
        let search = Command(id: "search", title: "Search mail for \u{201C}\(raw)\u{201D}",
                             icon: "magnifyingglass") { s in
            s.searchText = raw
            s.reloadThreads()
            // Land keyboard focus on the results so j/k work right away.
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
                if s.selectedThreadId == nil { s.moveSelection(1) }
            }
        }
        return [search] + commands.filter { $0.title.lowercased().contains(q) }
    }

    private func run(_ cmd: Command?) {
        guard let cmd else { return }
        store.showCommandPalette = false
        cmd.action(store)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
