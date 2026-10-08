import SwiftUI

/// Cmd-K palette: jump to views, compose, sync.
struct CommandPalette: View {
    @Environment(MailStore.self) var store
    @Environment(\.openSettings) private var openSettings
    // `commands` reads `store.selectedThread`; selection publishes through
    // ListFocusState (not MailStore), so observe it to keep the context
    // actions fresh. Cheap: the palette is mounted only while open.
    @EnvironmentObject var listFocus: ListFocusState
    @State private var query = ""
    @State private var highlighted = 0
    /// Bumped by arrow keys only, so hover never scrolls the list.
    @State private var keyboardHighlight = 0
    @FocusState private var focused: Bool

    struct Command: Identifiable {
        let id: String
        let title: String
        let icon: String
        let shortcut: ShortcutCommand?
        let action: (MailStore) -> Void

        init(id: String, title: String, icon: String,
             shortcut: ShortcutCommand? = nil,
             action: @escaping (MailStore) -> Void) {
            self.id = id
            self.title = title
            self.icon = icon
            self.shortcut = shortcut
            self.action = action
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .onTapGesture { store.showCommandPalette = false }

            VStack(spacing: 0) {
                TextField("Search mail (from: to: subject: is:unread…) or type a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .padding(14)
                    .focused($focused)
                    .onSubmit { run(filtered[safe: highlighted]) }
                    .onChange(of: query) { highlighted = 0 }
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        // Inner list padding so highlight pills sit concentrically inside the 12pt shell.
                        LazyVStack(spacing: 2) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, cmd in
                                Button { run(cmd) } label: {
                                    HStack {
                                        Image(systemName: cmd.icon).frame(width: 20)
                                        Text(cmd.title)
                                        Spacer()
                                        if let shortcut = cmd.shortcut {
                                            Text(store.keyBindings.key(for: shortcut))
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(
                                        idx == highlighted ? Color.notionAccent.opacity(0.2) : .clear,
                                        in: RoundedRectangle(cornerRadius: PMRadius.sm)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(cmd.id)
                                .accessibilityAddTraits(idx == highlighted ? .isSelected : [])
                                .onHover { if $0 { highlighted = idx } }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 280)
                    // Scroll only for arrow keys. Following hover would scroll
                    // a new row under a still pointer and walk the list.
                    .onChange(of: keyboardHighlight) { _, _ in
                        guard let id = filtered[safe: highlighted]?.id else { return }
                        proxy.scrollTo(id)
                    }
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: PMRadius.lg))
            .frame(width: 480)
            .pmCardElevation(cornerRadius: PMRadius.lg, intense: true)
            .padding(.top, 120)
            .onAppear {
                // Focus reliably once the overlay is in the hierarchy.
                focused = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { focused = true }
            }
            .onKeyPress(.downArrow) {
                highlighted = min(highlighted + 1, filtered.count - 1)
                keyboardHighlight &+= 1
                return .handled
            }
            .onKeyPress(.upArrow) {
                highlighted = max(highlighted - 1, 0)
                keyboardHighlight &+= 1
                return .handled
            }
        }
    }

    /// Rows come from `PaletteCommands` (pure, unit-tested); this view only
    /// supplies the context and turns each action into a store call.
    private var commands: [Command] {
        let checkedIds = store.checkedThreadIds
        let context = PaletteCommands.Context(
            focused: store.selectedThread.map {
                .init(isStarred: $0.isStarred, isUnread: $0.isUnread)
            },
            checked: checkedIds.isEmpty ? [] : store.threads
                .filter { checkedIds.contains($0.id) }
                .map { .init(isStarred: $0.isStarred, isUnread: $0.isUnread) },
            checkedCount: checkedIds.count,
            savedViews: store.savedViews.map { .init(id: $0.id ?? -1, name: $0.name) })
        return PaletteCommands.entries(context).map { entry in
            Command(id: entry.id, title: entry.title, icon: entry.icon,
                    shortcut: entry.shortcut) { [openSettings] store in
                Self.run(entry.action, on: store, openSettings: openSettings)
            }
        }
    }

    private static func run(_ action: PaletteCommands.Action, on store: MailStore,
                            openSettings: OpenSettingsAction) {
        switch action {
        case .compose:
            store.openCompose(.init(replyTo: nil))
        case .syncAll:
            Task { await store.syncAll() }
        case .toggleAskMish:
            store.showAskMish.toggle()
        case .sortInboxWithAI:
            store.classifyInbox()
        case .addView:
            store.editingView = SavedView.empty()
        case .notionMailSettings:
            UserDefaults.standard.set(SettingsView.Pane.notionMail.rawValue,
                                      forKey: "settingsPane")
            openSettings()
            store.showCommandPalette = false
        case .perform(let command):
            store.perform(command)
        case .snoozeTomorrow:
            let date = MailStore.snoozeDate(hour: 8, addDays: 1)
            if !store.checkedThreadIds.isEmpty {
                store.snoozeChecked(until: date)
            } else if let thread = store.selectedThread {
                store.snooze(thread, until: date)
            }
        case .copyLink:
            if let thread = store.selectedThread { store.copyThreadLink(thread) }
        case .goTo(let mailbox):
            store.goTo(mailboxView(mailbox))
        case .goToSaved(let id, let name):
            store.goTo(.saved(id, name))
        case .search(let text):
            store.commitSearch(text)
        }
    }

    private static func mailboxView(_ mailbox: BuiltinMailbox) -> MailboxView {
        switch mailbox {
        case .inbox: return .inbox
        case .promotions: return .promotions
        case .social: return .social
        case .starred: return .starred
        case .snoozed: return .snoozed
        case .reminders: return .reminders
        case .drafts: return .drafts
        case .sent: return .sent
        case .allMail: return .allMail
        case .trash: return .trash
        }
    }

    private var filtered: [Command] {
        let raw = query.trimmingCharacters(in: .whitespaces)
        let q = raw.lowercased()
        guard !q.isEmpty else { return commands }
        // Search is always the first, default action for any typed text.
        let search = Command(id: "search", title: "Search mail for \u{201C}\(raw)\u{201D}",
                             icon: "magnifyingglass") { s in
            s.commitSearch(raw)
            // Land keyboard focus on the results so j/k work right away.
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
                if s.selectedThreadId == nil { s.moveSelection(1) }
            }
        }
        // Fuzzy subsequence match, ranked so tighter matches float up.
        let scored = commands
            .compactMap { cmd -> (Command, Int)? in
                guard let score = Self.fuzzyScore(q, cmd.title.lowercased()) else { return nil }
                return (cmd, score)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        return [search] + scored
    }

    /// Returns nil when `query`'s characters don't appear in order in `text`;
    /// otherwise a score where lower is a tighter (more contiguous, earlier)
    /// match.
    static func fuzzyScore(_ query: String, _ text: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        var qi = query.startIndex
        var firstHit: Int?
        var lastHit = 0
        var gaps = 0
        for (offset, ch) in text.enumerated() {
            if ch == query[qi] {
                if firstHit == nil { firstHit = offset }
                if let _ = firstHit, offset - lastHit > 1, firstHit != offset { gaps += offset - lastHit - 1 }
                lastHit = offset
                qi = query.index(after: qi)
                if qi == query.endIndex {
                    return (firstHit ?? 0) + gaps
                }
            }
        }
        return nil
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
