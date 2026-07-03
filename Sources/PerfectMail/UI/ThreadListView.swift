import SwiftUI

struct ThreadListView: View {
    @EnvironmentObject var store: MailStore

    private var grouped: [(String, [MailThread])] {
        let cal = Calendar.current
        let now = Date()
        var groups: [(String, [MailThread])] = []
        var buckets: [String: [MailThread]] = [:]
        let order = ["Today", "Yesterday", "Last 7 days", "Last 30 days", "Older"]
        for thread in store.threads {
            let key: String
            if cal.isDateInToday(thread.lastDate) { key = "Today" }
            else if cal.isDateInYesterday(thread.lastDate) { key = "Yesterday" }
            else if thread.lastDate > now.addingTimeInterval(-7 * 86400) { key = "Last 7 days" }
            else if thread.lastDate > now.addingTimeInterval(-30 * 86400) { key = "Last 30 days" }
            else { key = "Older" }
            buckets[key, default: []].append(thread)
        }
        for key in order where buckets[key] != nil {
            groups.append((key, buckets[key]!))
        }
        return groups
    }

    var body: some View {
        VStack(spacing: 0) {
            FilterBar()
            Divider()
            List(selection: $store.selectedThreadId) {
                ForEach(grouped, id: \.0) { title, threads in
                    Section(title) {
                        ForEach(threads) { thread in
                            ThreadRow(thread: thread)
                                .tag(thread.id)
                                .swipeActions(edge: .trailing) {
                                    Button { store.archive(thread) } label: {
                                        Label("Archive", systemImage: "archivebox")
                                    }.tint(.green)
                                    Button(role: .destructive) { store.trash(thread) } label: {
                                        Label("Trash", systemImage: "trash")
                                    }
                                }
                                .contextMenu { threadMenu(thread) }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle(store.selectedView.title)
        .overlay {
            if store.threads.isEmpty {
                ContentUnavailableView(
                    store.accounts.isEmpty ? "No accounts connected" : "Nothing here",
                    systemImage: store.accounts.isEmpty ? "person.crop.circle.badge.plus" : "tray",
                    description: Text(store.accounts.isEmpty
                        ? "Add a Google account from the account menu to get started."
                        : "You're all caught up.")
                )
            }
        }
        .overlay(alignment: .bottom) {
            if let undo = store.undoAction {
                HStack(spacing: 12) {
                    Text(undo.label)
                    Button("Undo") { undo.undo() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("z", modifiers: .command)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 8)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: store.undoAction?.id)
    }

    @ViewBuilder
    private func threadMenu(_ thread: MailThread) -> some View {
        Button("Archive") { store.archive(thread) }
        Button(thread.isStarred ? "Unstar" : "Star") { store.toggleStar(thread) }
        Button(thread.isUnread ? "Mark Read" : "Mark Unread") {
            store.setRead(thread, read: thread.isUnread)
        }
        Menu("Snooze") {
            Button("This evening (6 PM)") { store.snooze(thread, until: MailStore.snoozeDate(hour: 18)) }
            Button("Tomorrow morning (8 AM)") { store.snooze(thread, until: MailStore.snoozeDate(hour: 8, addDays: 1)) }
            Button("Next week") { store.snooze(thread, until: MailStore.snoozeDate(hour: 8, addDays: 7)) }
            if thread.snoozeUntil != nil {
                Button("Unsnooze") { store.snooze(thread, until: nil) }
            }
        }
        Menu("Remind me") {
            Button("Tomorrow") { store.setReminder(thread, after: 1) }
            Button("In 3 days") { store.setReminder(thread, after: 3) }
            Button("In a week") { store.setReminder(thread, after: 7) }
            if thread.reminderAt != nil {
                Button("Clear reminder") { store.setReminder(thread, after: nil) }
            }
        }
        Divider()
        Button("Trash", role: .destructive) { store.trash(thread) }
    }
}

/// Notion Mail-style filter chips above the list, with click-to-refresh.
struct FilterBar: View {
    @EnvironmentObject var store: MailStore
    @State private var senderDraft = ""
    @State private var showFilterPopover = false

    private var defaultChips: FilterChips { FilterChips.defaults(for: store.selectedView) }

    var body: some View {
        HStack(spacing: 8) {
            // Categories — the one always-visible chip, like Notion Mail.
            Menu {
                Button("Not Promotions, Social") { store.chips.category = .notPromoSocial }
                Button("All categories") { store.chips.category = .all }
                Divider()
                ForEach(Array(CategoryChip.names.keys.sorted()), id: \.self) { cat in
                    Button(CategoryChip.names[cat] ?? cat) { store.chips.category = .only(cat) }
                }
            } label: {
                chipLabel("Categories: \(store.chips.category.title)",
                          icon: "bookmark",
                          active: store.chips.category != defaultChips.category)
            }
            .menuStyle(.borderlessButton).fixedSize()

            // Chips for whatever filters are active, each removable.
            if let name = store.chips.labelName {
                activeChip("Label: \(name)") { store.chips.labelId = nil; store.chips.labelName = nil }
            }
            if store.chips.unreadOnly { activeChip("Unread") { store.chips.unreadOnly = false } }
            if store.chips.showArchived { activeChip("Archived") { store.chips.showArchived = false } }
            if store.chips.hasAttachmentOnly { activeChip("Attachment") { store.chips.hasAttachmentOnly = false } }
            if !store.chips.senderContains.isEmpty {
                activeChip("From: \(store.chips.senderContains)") {
                    store.chips.senderContains = ""; senderDraft = ""
                }
            }

            // Everything else lives behind one "+ Filter".
            Button {
                showFilterPopover = true
            } label: {
                chipLabel("Filter", icon: "plus", active: false)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showFilterPopover, arrowEdge: .bottom) {
                filterPopover
            }

            Spacer(minLength: 4)

            // Click to update.
            Button {
                Task { await store.syncAll() }
            } label: {
                HStack(spacing: 4) {
                    if store.syncStatus.isEmpty {
                        Image(systemName: "arrow.clockwise")
                        if let last = lastSync {
                            Text(last, format: .relative(presentation: .named))
                        }
                    } else {
                        ProgressView().controlSize(.mini)
                        Text(store.syncStatus)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Sync now (Cmd-Shift-R)")
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private var filterPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Unread only", isOn: $store.chips.unreadOnly)
            Toggle("Show archived", isOn: $store.chips.showArchived)
            Toggle("Has attachment", isOn: $store.chips.hasAttachmentOnly)
            Picker("Label", selection: $store.chips.labelId) {
                Text("Any").tag(String?.none)
                ForEach(allLabels, id: \.gmailLabelId) { label in
                    Text(label.name).tag(String?.some(label.gmailLabelId))
                }
            }
            .onChange(of: store.chips.labelId) {
                store.chips.labelName = allLabels.first { $0.gmailLabelId == store.chips.labelId }?.name
            }
            TextField("From contains…", text: $senderDraft)
                .onSubmit { store.chips.senderContains = senderDraft }
            HStack {
                if store.chips != defaultChips {
                    Button("Clear all") {
                        store.chips = defaultChips
                        senderDraft = ""
                    }
                    Spacer()
                    Button("Save as view…") {
                        var v = SavedView.empty()
                        v.name = store.selectedView.title + " (filtered)"
                        v.labelId = store.chips.labelId
                        v.unreadOnly = store.chips.unreadOnly
                        v.showArchived = store.chips.showArchived
                        v.hasAttachmentOnly = store.chips.hasAttachmentOnly
                        v.senderContains = store.chips.senderContains
                        v.accountId = store.activeAccountId
                        if store.chips.category == .notPromoSocial { v.excludePromotions = true }
                        if case .only(let cat) = store.chips.category { v.category = cat }
                        showFilterPopover = false
                        store.editingView = v
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private func activeChip(_ title: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.2), in: Capsule())
    }

    private var lastSync: Date? {
        store.accounts.compactMap(\.lastSyncAt).min()
    }

    private var allLabels: [LabelRow] {
        let labels = store.labelsByAccount.values.flatMap { $0 }
        var seen = Set<String>()
        return labels.filter { seen.insert($0.gmailLabelId).inserted }.sorted { $0.name < $1.name }
    }

    private func chipLabel(_ title: String, icon: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption)
            Text(title).font(.caption)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(active ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1),
                    in: Capsule())
    }
}

/// Dense Notion Mail-style single-line row:
/// [dot] participants   subject  snippet………………  [icons] time
struct ThreadRow: View {
    @EnvironmentObject var store: MailStore
    let thread: MailThread
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(thread.isUnread ? Color.accentColor : .clear)
                .frame(width: 7, height: 7)

            HStack(spacing: 4) {
                Text(participantsDisplay)
                    .font(.system(size: 13, weight: thread.isUnread ? .semibold : .regular))
                    .lineLimit(1)
                if thread.messageCount > 1 {
                    Text("\(thread.messageCount)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 170, alignment: .leading)

            (Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                .fontWeight(thread.isUnread ? .semibold : .medium)
             + Text("  \(thread.snippet)")
                .foregroundColor(.secondary))
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer(minLength: 8)

            if hovering {
                HStack(spacing: 2) {
                    hoverButton("star", filled: thread.isStarred) { store.toggleStar(thread) }
                    hoverButton("archivebox") { store.archive(thread) }
                    hoverButton("clock") { store.snooze(thread, until: MailStore.snoozeDate(hour: 8, addDays: 1)) }
                    hoverButton("trash") { store.trash(thread) }
                }
            } else {
                HStack(spacing: 5) {
                    if thread.hasAttachment {
                        Image(systemName: "paperclip").font(.caption2).foregroundStyle(.secondary)
                    }
                    if thread.reminderAt != nil {
                        Image(systemName: "bell.fill").font(.caption2).foregroundStyle(.orange)
                    }
                    if thread.isStarred {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                    Text(thread.lastDate, format: relativeFormat)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(minWidth: 52, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 2)
        .onHover { hovering = $0 }
    }

    private var participantsDisplay: String {
        thread.participants.isEmpty ? thread.fromDisplay : thread.participants
    }

    private func hoverButton(_ icon: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: filled ? "\(icon).fill" : icon)
                .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .padding(2)
    }

    private var relativeFormat: Date.FormatStyle {
        Calendar.current.isDateInToday(thread.lastDate)
            ? .dateTime.hour().minute()
            : .dateTime.month(.abbreviated).day()
    }
}
