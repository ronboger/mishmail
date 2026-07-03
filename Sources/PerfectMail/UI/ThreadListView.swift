import SwiftUI

enum GroupBy: String, CaseIterable {
    case date, starred, important, sender, label, unread

    var title: String {
        switch self {
        case .date: return "Date"
        case .starred: return "Starred"
        case .important: return "Important"
        case .sender: return "Email or domain"
        case .label: return "Labels"
        case .unread: return "Unread"
        }
    }

    var icon: String {
        switch self {
        case .date: return "calendar"
        case .starred: return "star"
        case .important: return "exclamationmark.circle"
        case .sender: return "at"
        case .label: return "tag"
        case .unread: return "envelope.badge"
        }
    }
}

struct ThreadListView: View {
    @EnvironmentObject var store: MailStore
    @AppStorage("groupBy") private var groupByRaw = GroupBy.date.rawValue

    private var groupBy: GroupBy { GroupBy(rawValue: groupByRaw) ?? .date }

    private var grouped: [(String, [MailThread])] {
        switch groupBy {
        case .date: return groupedByDate
        case .starred: return partition("Starred", "Everything else") { $0.isStarred }
        case .important: return partition("Important", "Everything else") { $0.labels.contains("IMPORTANT") }
        case .unread: return partition("Unread", "Read") { $0.isUnread }
        case .sender: return groupedBy { $0.fromDisplay }
        case .label: return groupedBy { thread in
            let userLabel = thread.labels
                .compactMap { store.labelName($0, account: thread.accountId) }
                .sorted().first
            return userLabel ?? "No label"
        }
        }
    }

    private var groupedByDate: [(String, [MailThread])] {
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

    private func partition(_ yes: String, _ no: String,
                           test: (MailThread) -> Bool) -> [(String, [MailThread])] {
        let hits = store.threads.filter(test)
        let misses = store.threads.filter { !test($0) }
        var out: [(String, [MailThread])] = []
        if !hits.isEmpty { out.append((yes, hits)) }
        if !misses.isEmpty { out.append((no, misses)) }
        return out
    }

    private func groupedBy(_ key: (MailThread) -> String) -> [(String, [MailThread])] {
        let buckets = Dictionary(grouping: store.threads, by: key)
        return buckets
            .sorted { ($0.value.first?.lastDate ?? .distantPast) > ($1.value.first?.lastDate ?? .distantPast) }
            .map { ($0.key, $0.value) }
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
    @State private var showCategoriesPopover = false
    @AppStorage("groupBy") private var groupByRaw = GroupBy.date.rawValue
    @AppStorage("showCategoryChip") private var showCategoryChip = true
    @AppStorage("showFilterChip") private var showFilterChip = true

    private var defaultChips: FilterChips { FilterChips.defaults(for: store.selectedView) }

    var body: some View {
        HStack(spacing: 8) {
            // Categories — the one always-visible chip, like Notion Mail.
            if showCategoryChip {
                Button {
                    showCategoriesPopover = true
                } label: {
                    chipLabel("Categories: \(store.chips.category.title)",
                              icon: "bookmark",
                              active: store.chips.category != defaultChips.category)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showCategoriesPopover, arrowEdge: .bottom) {
                    CategoriesPopover()
                }
            }

            // Chips for whatever filters are active, each removable.
            if let name = store.chips.labelName {
                activeChip("Label\(store.chips.labelExclude ? " ≠" : ":") \(name)") {
                    store.chips.labelId = nil; store.chips.labelName = nil
                }
            }
            if store.chips.unreadOnly { activeChip("Unread") { store.chips.unreadOnly = false } }
            if store.chips.showArchived { activeChip("Archived") { store.chips.showArchived = false } }
            if store.chips.hasAttachmentOnly { activeChip("Attachment") { store.chips.hasAttachmentOnly = false } }
            if !store.chips.senderContains.isEmpty {
                activeChip("From\(store.chips.senderExclude ? " ≠" : ":") \(store.chips.senderContains)") {
                    store.chips.senderContains = ""; senderDraft = ""
                }
            }

            // Everything else lives behind one "+ Filter".
            if showFilterChip {
                Button {
                    showFilterPopover = true
                } label: {
                    chipLabel("Filter", icon: "plus", active: false)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showFilterPopover, arrowEdge: .bottom) {
                    filterPopover
                }
            }

            Spacer(minLength: 4)

            // View options: grouping + which chips to show.
            Menu {
                Picker("Group by", selection: $groupByRaw) {
                    ForEach(GroupBy.allCases, id: \.rawValue) { g in
                        Label(g.title, systemImage: g.icon).tag(g.rawValue)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Show Categories filter", isOn: $showCategoryChip)
                Toggle("Show + Filter", isOn: $showFilterChip)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Group and display options")

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

            Divider()

            HStack(spacing: 6) {
                Text("Label")
                Menu(store.chips.labelExclude ? "does not contain" : "contains") {
                    Button("contains") { store.chips.labelExclude = false }
                    Button("does not contain") { store.chips.labelExclude = true }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .font(.caption).foregroundStyle(.secondary)
            }
            Picker("", selection: $store.chips.labelId) {
                Text("Any").tag(String?.none)
                ForEach(allLabels, id: \.gmailLabelId) { label in
                    Text(label.name).tag(String?.some(label.gmailLabelId))
                }
            }
            .labelsHidden()
            .onChange(of: store.chips.labelId) {
                store.chips.labelName = allLabels.first { $0.gmailLabelId == store.chips.labelId }?.name
            }

            HStack(spacing: 6) {
                Text("From")
                Menu(store.chips.senderExclude ? "does not contain" : "contains") {
                    Button("contains") { store.chips.senderExclude = false }
                    Button("does not contain") { store.chips.senderExclude = true }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .font(.caption).foregroundStyle(.secondary)
            }
            TextField("Name or address…", text: $senderDraft)
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
                        if store.chips.category.exclude,
                           store.chips.category.categories.isSuperset(of: ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL"]) {
                            v.excludePromotions = true
                        }
                        if !store.chips.category.exclude,
                           let cat = store.chips.category.categories.first {
                            v.category = cat
                        }
                        showFilterPopover = false
                        store.editingView = v
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 270)
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
    @AppStorage("fontScale") private var fontScale = 1.0
    let thread: MailThread
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Colored initial avatar, unread dot on its corner.
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(Color.stable(for: avatarKey).gradient)
                    .frame(width: 24 * fontScale, height: 24 * fontScale)
                    .overlay {
                        Text(initials)
                            .font(.system(size: 10.5 * fontScale, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                if thread.isUnread {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .offset(x: 2, y: -2)
                }
            }

            HStack(spacing: 4) {
                Text(participantsDisplay)
                    .font(.system(size: 14 * fontScale, weight: thread.isUnread ? .semibold : .regular))
                    .lineLimit(1)
                if thread.messageCount > 1 {
                    Text("\(thread.messageCount)")
                        .font(.system(size: 11.5 * fontScale)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 180 * fontScale, alignment: .leading)

            (Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                .fontWeight(thread.isUnread ? .semibold : .medium)
             + Text("  \(thread.snippet)")
                .foregroundColor(.secondary))
                .font(.system(size: 14 * fontScale))
                .lineLimit(1)

            Spacer(minLength: 8)

            // Fixed-height trailing area: icons overlay the timestamp on
            // hover so the row never changes size.
            ZStack(alignment: .trailing) {
                HStack(spacing: 5) {
                    if thread.hasAttachment {
                        Image(systemName: "paperclip")
                            .font(.system(size: 12 * fontScale)).foregroundStyle(.secondary)
                    }
                    if thread.reminderAt != nil {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 12 * fontScale)).foregroundStyle(.orange)
                    }
                    if thread.isStarred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 12 * fontScale)).foregroundStyle(.yellow)
                    }
                    Text(thread.lastDate, format: relativeFormat)
                        .font(.system(size: 12 * fontScale)).foregroundStyle(.secondary)
                        .frame(minWidth: 52, alignment: .trailing)
                }
                .opacity(hovering ? 0 : 1)

                HStack(spacing: 2) {
                    hoverButton("star", filled: thread.isStarred) { store.toggleStar(thread) }
                    hoverButton("archivebox") { store.archive(thread) }
                    hoverButton("clock") { store.snooze(thread, until: MailStore.snoozeDate(hour: 8, addDays: 1)) }
                    hoverButton("trash") { store.trash(thread) }
                }
                .opacity(hovering ? 1 : 0)
            }
            .frame(height: 18 * fontScale)
        }
        .padding(.vertical, 3 * fontScale)
        .onHover { hovering = $0 }
    }

    private var participantsDisplay: String {
        thread.participants.isEmpty ? thread.fromDisplay : thread.participants
    }

    /// Avatar keyed to the counterparty (skip "me" so replies keep the
    /// other person's color).
    private var avatarKey: String {
        let first = thread.participants.split(separator: " .. ").first { $0 != "me" }
        return first.map(String.init) ?? thread.fromDisplay
    }

    private var initials: String {
        let words = avatarKey.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }
        let joined = letters.joined().uppercased()
        return joined.isEmpty ? "?" : String(joined.prefix(2))
    }

    private func hoverButton(_ icon: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: filled ? "\(icon).fill" : icon)
                .font(.system(size: 13 * fontScale))
                .foregroundStyle(filled && icon == "star" ? .yellow : .secondary)
        }
        .buttonStyle(.plain)
        .padding(3)
    }

    private var relativeFormat: Date.FormatStyle {
        Calendar.current.isDateInToday(thread.lastDate)
            ? .dateTime.hour().minute()
            : .dateTime.month(.abbreviated).day()
    }
}

/// Notion Mail-style categories popover: contains / does-not-contain mode,
/// selected categories as removable chips, checkboxes, and a clear action.
struct CategoriesPopover: View {
    @EnvironmentObject var store: MailStore

    private var filter: Binding<CategoryFilter> {
        Binding(get: { store.chips.category }, set: { store.chips.category = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Categories")
                    .font(.system(size: 12, weight: .semibold))
                Menu(filter.wrappedValue.exclude ? "do not contain" : "contain") {
                    Button("do not contain") { filter.wrappedValue.exclude = true }
                    Button("contain") { filter.wrappedValue.exclude = false }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }

            // Selected categories as removable chips.
            if filter.wrappedValue.isActive {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(filter.wrappedValue.categories.sorted(), id: \.self) { cat in
                            HStack(spacing: 4) {
                                Circle().fill(Color.category(cat)).frame(width: 6, height: 6)
                                Text(CategoryFilter.names[cat] ?? cat)
                                    .font(.caption).lineLimit(1).fixedSize()
                                Button {
                                    filter.wrappedValue.categories.remove(cat)
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.category(cat).opacity(0.15), in: Capsule())
                        }
                    }
                    .padding(6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.6)))
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(CategoryFilter.names.keys.sorted()), id: \.self) { cat in
                    Toggle(isOn: Binding(
                        get: { filter.wrappedValue.categories.contains(cat) },
                        set: { on in
                            if on { filter.wrappedValue.categories.insert(cat) }
                            else { filter.wrappedValue.categories.remove(cat) }
                        }
                    )) {
                        HStack(spacing: 6) {
                            Circle().fill(Color.category(cat)).frame(width: 8, height: 8)
                            Text(CategoryFilter.names[cat] ?? cat)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                }
            }

            Divider()

            Button {
                filter.wrappedValue.categories = []
            } label: {
                Label("Clear filter", systemImage: "xmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 250)
    }
}
