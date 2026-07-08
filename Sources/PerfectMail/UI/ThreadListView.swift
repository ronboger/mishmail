import SwiftUI

enum GroupBy: String, CaseIterable {
    case date, starred, important, sender, label, unread, aiCategory

    var title: String {
        switch self {
        case .date: return "Date"
        case .starred: return "Starred"
        case .important: return "Important"
        case .sender: return "Email or domain"
        case .label: return "Labels"
        case .unread: return "Unread"
        case .aiCategory: return "AI category"
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
        case .aiCategory: return "sparkles"
        }
    }
}

struct ThreadListView: View {
    @EnvironmentObject var store: MailStore
    @AppStorage("groupBy") private var groupByRaw = GroupBy.date.rawValue
    @AppStorage("fontScale") private var fontScale = 1.0
    @AppStorage("priorityMode") private var priorityModeRaw = PrioritySplit.Mode.starred.rawValue
    @AppStorage("vipAlwaysPins") private var vipAlwaysPins = true

    private var groupBy: GroupBy { GroupBy(rawValue: groupByRaw) ?? .date }

    private var grouped: [(String, [MailThread])] {
        // Superhuman-style split inbox: qualifying threads pin to a Priority
        // section on top (what qualifies is the Settings → Appearance mode);
        // the chosen grouping applies to the rest. Inbox only — dedicated
        // views (Starred, Sent…) stay flat.
        let mode = PrioritySplit.Mode(rawValue: priorityModeRaw) ?? .starred
        let (priority, rest) = PrioritySplit.partition(
            store.threads,
            mode: store.selectedView == .inbox ? mode : .off,
            vipThreadIds: store.vipThreadIds,
            vipAlwaysPins: vipAlwaysPins)
        var out: [(String, [MailThread])] = []
        if !priority.isEmpty { out.append((Self.prioritySection, priority)) }
        out += groups(rest)
        return out
    }

    private static let prioritySection = "Priority"

    private func groups(_ threads: [MailThread]) -> [(String, [MailThread])] {
        switch groupBy {
        case .date: return groupedByDate(threads)
        case .starred: return partition(threads, "Starred", "Everything else") { $0.isStarred }
        case .important: return partition(threads, "Important", "Everything else") { $0.labels.contains("IMPORTANT") }
        case .unread: return partition(threads, "Unread", "Read") { $0.isUnread }
        case .sender: return groupedBy(threads) { $0.fromDisplay }
        case .label: return groupedBy(threads) { thread in
            let userLabel = thread.labels
                .compactMap { store.labelName($0, account: thread.accountId) }
                .sorted().first
            return userLabel ?? "No label"
        }
        case .aiCategory: return groupedBy(threads) { store.aiCategories[$0.id] ?? "Unsorted" }
        }
    }

    private func groupedByDate(_ threads: [MailThread]) -> [(String, [MailThread])] {
        let cal = Calendar.current
        let now = Date()
        var groups: [(String, [MailThread])] = []
        var buckets: [String: [MailThread]] = [:]
        let order = ["Today", "Yesterday", "Last 7 days", "Last 30 days", "Older"]
        for thread in threads {
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

    private func partition(_ threads: [MailThread], _ yes: String, _ no: String,
                           test: (MailThread) -> Bool) -> [(String, [MailThread])] {
        let hits = threads.filter(test)
        let misses = threads.filter { !test($0) }
        var out: [(String, [MailThread])] = []
        if !hits.isEmpty { out.append((yes, hits)) }
        if !misses.isEmpty { out.append((no, misses)) }
        return out
    }

    private func groupedBy(_ threads: [MailThread],
                           _ key: (MailThread) -> String) -> [(String, [MailThread])] {
        let buckets = Dictionary(grouping: threads, by: key)
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
                    Section {
                        ForEach(threads) { thread in
                            ThreadRow(thread: thread)
                                .tag(thread.id)
                                // Notion Mail-style: READ rows recede on a
                                // grey wash (adapts to dark mode); unread rows
                                // sit on the plain background and pop.
                                .listRowBackground(thread.isUnread
                                    ? Color.clear : Color.primary.opacity(0.05))
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
                    } header: {
                        // Compact so the pinned (sticky) header stays a thin
                        // line while scrolling. Secondary gray adapts to the
                        // theme and sets headers clearly apart from thread text.
                        HStack(spacing: 4) {
                            if title == Self.prioritySection {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9 * fontScale))
                                    .foregroundStyle(.orange)
                            }
                            Text(title)
                        }
                        .font(.system(size: 12 * fontScale, weight: .semibold))
                        .foregroundStyle(.secondary)
                    } footer: {
                        // The air lives AFTER each group, so every gap between
                        // groups is this exact height.
                        Color.clear.frame(height: 40 * fontScale)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Matching air above the first group.
            .contentMargins(.top, 40 * fontScale, for: .scrollContent)
            // Archived/trashed rows slide out instead of blinking away.
            .animation(.easeOut(duration: 0.2), value: store.threads)
        }
        .background(Color.notionContent)
        .navigationTitle(store.selectedView.title)
        .toolbar {
            // The view's colored icon next to its title, like Notion Mail's
            // red inbox glyph.
            ToolbarItem(placement: .navigation) {
                Image(systemName: store.selectedView.icon)
                    .foregroundStyle(store.selectedView.iconColor)
            }
            // While searching, let the user reach past the local cache to Gmail.
            if !store.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                ToolbarItem(placement: .automatic) {
                    Button { store.searchAllGmail() } label: {
                        Label(store.serverSearching ? "Searching…" : "Search all of Gmail",
                              systemImage: "magnifyingglass.circle")
                    }
                    .disabled(store.serverSearching)
                    .help("Pull matching messages from Gmail, beyond the local cache")
                }
            }
        }
        .overlay {
            if store.threads.isEmpty {
                if !store.accounts.isEmpty, !store.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Local search only covers cached mail — offer the server.
                    ContentUnavailableView {
                        Label("No local matches", systemImage: "magnifyingglass")
                    } description: {
                        Text("Nothing cached matches “\(store.searchText)”. Older mail may still be on Gmail.")
                    } actions: {
                        Button { store.searchAllGmail() } label: {
                            Label(store.serverSearching ? "Searching…" : "Search all of Gmail",
                                  systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.serverSearching)
                    }
                } else {
                    ContentUnavailableView(
                        store.accounts.isEmpty ? "No accounts connected" : "Nothing here",
                        systemImage: store.accounts.isEmpty ? "person.crop.circle.badge.plus" : "tray",
                        description: Text(store.accounts.isEmpty
                            ? "Add a Google account from the account menu to get started."
                            : "You're all caught up.")
                    )
                }
            }
        }
        // Undo/notice toast lives in ContentView, centered over the whole window.
    }

    @ViewBuilder
    private func threadMenu(_ thread: MailThread) -> some View {
        if thread.labels.contains("DRAFT") {
            Button("Edit Draft") { store.editDraft(inThread: thread) }
            Button("Delete Draft", role: .destructive) { store.confirmingDraftDelete = thread }
            Divider()
        }
        Button("Archive") { store.archive(thread) }
        Button(thread.isStarred ? "Unstar" : "Star") { store.toggleStar(thread) }
        Button(thread.isUnread ? "Mark Read" : "Mark Unread") {
            store.setRead(thread, read: thread.isUnread)
        }
        Menu("Snooze") {
            Button("This evening (6 PM)") { store.snooze(thread, until: MailStore.snoozeDate(hour: 18)) }
            Button("Tomorrow morning (8 AM)") { store.snooze(thread, until: MailStore.snoozeDate(hour: 8, addDays: 1)) }
            Button("Next week") { store.snooze(thread, until: MailStore.snoozeDate(hour: 8, addDays: 7)) }
            Button("Pick date & time…") { store.snoozingThread = thread }
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
        if let email = store.senderEmail(of: thread) {
            Divider()
            if store.vipEmails.contains(email) {
                Button("Remove \(email) from VIPs") { store.removeVIP(email) }
            } else {
                Button("Add \(email) to VIPs") { store.addVIP(email) }
            }
        }
        Divider()
        Button("Trash", role: .destructive) { store.trash(thread) }
    }
}

/// Notion Mail-style filter chips above the list, with click-to-refresh.
struct FilterBar: View {
    @EnvironmentObject var store: MailStore
    @State private var showCategoriesPopover = false
    @State private var showLabelsPopover = false
    @State private var labelQuery = ""
    @State private var filterQuery = ""
    @State private var datePopoverTitle: String?
    @State private var editingField: FilterField?
    @State private var fieldDraft = ""
    @State private var fieldExclude = false
    @State private var showMore = false
    @AppStorage("groupBy") private var groupByRaw = GroupBy.date.rawValue
    @AppStorage("showCategoryChip") private var showCategoryChip = true
    @AppStorage("showFilterChip") private var showFilterChip = true

    private var defaultChips: FilterChips { FilterChips.defaults(for: store.selectedView) }

    enum FilterField {
        case from, to, cc, bcc, subject, label

        var title: String {
            switch self {
            case .from: return "From"
            case .to: return "To"
            case .cc: return "Cc"
            case .bcc: return "Bcc"
            case .subject: return "Subject"
            case .label: return "Label"
            }
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Categories — the one always-visible chip, like Notion Mail.
                    if showCategoryChip {
                        Button {
                            showCategoriesPopover = true
                        } label: {
                            chipLabel("Categories: \(store.chips.category.title)",
                                      icon: "bookmark.fill",
                                      active: store.chips.category.isActive)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showCategoriesPopover, arrowEdge: .bottom) {
                            CategoriesPopover()
                        }
                    }

                    // Always-visible quick filters, Notion Mail-style:
                    // Labels dropdown, Is unread, Show archived.
                    labelsChip
                    quickChip("Is unread", icon: "envelope.badge",
                              active: store.chips.unreadOnly) {
                        store.chips.unreadOnly.toggle()
                        if store.chips.unreadOnly { store.chips.readOnly = false }
                    }
                    quickChip("Show archived", icon: "archivebox",
                              active: store.chips.showArchived) {
                        store.chips.showArchived.toggle()
                    }

                    // Chips for whatever other filters are active, each removable.
                    if store.chips.readOnly { activeChip("Read") { store.chips.readOnly = false } }
                    if store.chips.showSent { activeChip("Sent") { store.chips.showSent = false } }
                    if store.chips.hasAttachmentOnly { activeChip("Attachment") { store.chips.hasAttachmentOnly = false } }
                    if store.chips.noAttachmentOnly { activeChip("No attachment") { store.chips.noAttachmentOnly = false } }
                    if store.chips.calendarOnly { activeChip("Calendar events") { store.chips.calendarOnly = false } }
                    if store.chips.hideCalendar { activeChip("No calendar events") { store.chips.hideCalendar = false } }
                    if let window = store.chips.dateWindow {
                        activeChip("Date: \(window.title)") { store.chips.dateWindow = nil }
                    }
                    if !store.chips.senderContains.isEmpty {
                        activeChip("From\(store.chips.senderExclude ? " ≠" : ":") \(store.chips.senderContains)") {
                            store.chips.senderContains = ""
                        }
                    }
                    if !store.chips.toContains.isEmpty {
                        activeChip("To: \(store.chips.toContains)") { store.chips.toContains = "" }
                    }
                    if !store.chips.ccContains.isEmpty {
                        activeChip("Cc: \(store.chips.ccContains)") { store.chips.ccContains = "" }
                    }
                    if !store.chips.bccContains.isEmpty {
                        activeChip("Bcc: \(store.chips.bccContains)") { store.chips.bccContains = "" }
                    }
                    if !store.chips.subjectContains.isEmpty {
                        activeChip("Subject: \(store.chips.subjectContains)") { store.chips.subjectContains = "" }
                    }

                    // Everything else lives behind one "+ Filter" (Ctrl-F).
                    filterButton
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

    /// The "+ Filter" chip. Rendered as an invisible anchor when hidden so
    /// Ctrl-F can still open the popover.
    @ViewBuilder
    private var filterButton: some View {
        Group {
            if showFilterChip {
                Button {
                    store.showFilterMenu = true
                } label: {
                    chipLabel("Filter", icon: "plus", active: false)
                }
                .buttonStyle(.plain)
                .help("Filter (Ctrl-F)")
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .popover(isPresented: $store.showFilterMenu, arrowEdge: .bottom) {
            filterPopover
        }
        .onChange(of: store.showFilterMenu) {
            if store.showFilterMenu { editingField = nil; showMore = false; filterQuery = "" }
        }
    }

    /// Notion Mail-style filter menu: primary filters, "More filters"
    /// expansion, and per-field editors.
    @ViewBuilder
    private var filterPopover: some View {
        Group {
            if let field = editingField {
                fieldEditor(field)
            } else {
                filterMenu
            }
        }
        .padding(10)
        .frame(width: 260)
    }

    /// One entry in the "+ Filter" menu. Data-driven so the menu can be
    /// searched (type to narrow across the whole set, primary + "More").
    struct FilterOption: Identifiable {
        enum Kind {
            case field(FilterField)
            case date(String)
            case categories
            case mutate((inout FilterChips) -> Void)
            case showCategory(String)
            case hideCategory(String)
        }
        let icon: String
        let title: String
        let primary: Bool
        let kind: Kind
        var id: String { title }
    }

    /// The full ordered filter list. `primary` ones show before "More filters".
    private var filterOptions: [FilterOption] {
        [
            .init(icon: "person.crop.circle", title: "From", primary: true, kind: .field(.from)),
            .init(icon: "paperclip", title: "Has attachments", primary: true,
                  kind: .mutate { $0.hasAttachmentOnly = true; $0.noAttachmentOnly = false }),
            .init(icon: "calendar", title: "Date", primary: true, kind: .date("Date")),
            .init(icon: "calendar.badge.clock", title: "Only show calendar events", primary: true,
                  kind: .mutate { $0.calendarOnly = true; $0.hideCalendar = false }),
            .init(icon: "person.2", title: "Show \"social\" emails", primary: true,
                  kind: .showCategory("CATEGORY_SOCIAL")),
            .init(icon: "megaphone", title: "Show \"promotional\" emails", primary: true,
                  kind: .showCategory("CATEGORY_PROMOTIONS")),
            .init(icon: "tag", title: "Labels", primary: false, kind: .field(.label)),
            .init(icon: "bookmark", title: "Categories", primary: false, kind: .categories),
            .init(icon: "at", title: "To", primary: false, kind: .field(.to)),
            .init(icon: "at.badge.plus", title: "Cc", primary: false, kind: .field(.cc)),
            .init(icon: "eye.slash", title: "Bcc", primary: false, kind: .field(.bcc)),
            .init(icon: "textformat", title: "Subject", primary: false, kind: .field(.subject)),
            .init(icon: "clock.arrow.circlepath", title: "Received date", primary: false,
                  kind: .date("Received date")),
            .init(icon: "paperplane", title: "Show sent", primary: false,
                  kind: .mutate { $0.showSent = true }),
            .init(icon: "archivebox", title: "Show archived", primary: false,
                  kind: .mutate { $0.showArchived = true }),
            .init(icon: "envelope.open", title: "Is read", primary: false,
                  kind: .mutate { $0.readOnly = true; $0.unreadOnly = false }),
            .init(icon: "envelope.badge", title: "Is unread", primary: false,
                  kind: .mutate { $0.unreadOnly = true; $0.readOnly = false }),
            .init(icon: "paperclip.badge.ellipsis", title: "No attachments", primary: false,
                  kind: .mutate { $0.noAttachmentOnly = true; $0.hasAttachmentOnly = false }),
            .init(icon: "calendar.badge.minus", title: "Hide calendar events", primary: false,
                  kind: .mutate { $0.hideCalendar = true; $0.calendarOnly = false }),
            .init(icon: "bubble.left.and.bubble.right", title: "Show \"forums\" emails", primary: false,
                  kind: .showCategory("CATEGORY_FORUMS")),
            .init(icon: "bubble.left.and.bubble.right", title: "Hide \"forums\" emails", primary: false,
                  kind: .hideCategory("CATEGORY_FORUMS")),
            .init(icon: "info.circle", title: "Show \"updates\" emails", primary: false,
                  kind: .showCategory("CATEGORY_UPDATES")),
            .init(icon: "info.circle", title: "Hide \"updates\" emails", primary: false,
                  kind: .hideCategory("CATEGORY_UPDATES")),
        ]
    }

    private var filterMenu: some View {
        VStack(alignment: .leading, spacing: 1) {
            SearchField(prompt: "Search filters", text: $filterQuery, compact: true) {
                // Enter applies the first match (skipping the date rows, whose
                // action is their own sub-popover).
                let q = filterQuery.trimmingCharacters(in: .whitespaces).lowercased()
                guard !q.isEmpty,
                      let first = filterOptions.first(where: {
                          $0.title.lowercased().contains(q) && !isDateOption($0)
                      })
                else { return }
                activate(first)
            }
            .padding(.bottom, 4)

            let q = filterQuery.trimmingCharacters(in: .whitespaces).lowercased()
            if q.isEmpty {
                // Default layout: primary filters, then the "More filters" set.
                ForEach(filterOptions.filter(\.primary)) { optionRow($0) }
                if !showMore {
                    FilterMenuRow(icon: "ellipsis", title: "More filters") { showMore = true }
                } else {
                    Divider().padding(.vertical, 4)
                    ForEach(filterOptions.filter { !$0.primary }) { optionRow($0) }
                }
            } else {
                // Search across everything at once.
                let matches = filterOptions.filter { $0.title.lowercased().contains(q) }
                if matches.isEmpty {
                    Text("No filters match “\(filterQuery)”")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.vertical, 6).padding(.horizontal, 6)
                } else {
                    ForEach(matches) { optionRow($0) }
                }
            }

            if store.chips != defaultChips {
                Divider().padding(.vertical, 4)
                HStack {
                    Button("Clear all") { store.chips = defaultChips }
                    Spacer()
                    Button("Save as view…") { saveAsView() }
                }
                .font(.system(size: 12))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            }
        }
    }

    /// Renders one filter option. Date options keep their sub-popover; the rest
    /// are plain action rows.
    @ViewBuilder
    private func optionRow(_ option: FilterOption) -> some View {
        switch option.kind {
        case .date(let title):
            dateRow(icon: option.icon, title: title)
        default:
            FilterMenuRow(icon: option.icon, title: option.title) { activate(option) }
        }
    }

    private func isDateOption(_ option: FilterOption) -> Bool {
        if case .date = option.kind { return true }
        return false
    }

    private func activate(_ option: FilterOption) {
        switch option.kind {
        case .field(let field):
            beginEditing(field)
        case .date:
            break   // handled by dateRow's own popover
        case .categories:
            store.showFilterMenu = false
            DispatchQueue.main.async { showCategoriesPopover = true }
        case .mutate(let mutate):
            set(mutate)
        case .showCategory(let cat):
            showCategory(cat)
        case .hideCategory(let cat):
            hideCategory(cat)
        }
    }

    /// "Date" / "Received date": a plain FilterMenuRow that opens a popover of
    /// relative windows. Using a Button (not a borderless Menu) keeps the
    /// icon/text column pixel-aligned with the other rows — the menu style
    /// insets its own label, which pushed this row left of the rest.
    private func dateRow(icon: String, title: String) -> some View {
        FilterMenuRow(icon: icon, title: title,
                      trailing: store.chips.dateWindow != nil ? "chevron.right" : nil) {
            datePopoverTitle = title
        }
        .popover(isPresented: Binding(
            get: { datePopoverTitle == title },
            set: { if !$0 { datePopoverTitle = nil } }
        ), arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(DateWindow.allCases, id: \.rawValue) { window in
                    FilterMenuRow(
                        icon: store.chips.dateWindow == window ? "checkmark" : "circle",
                        title: window.title
                    ) {
                        store.chips.dateWindow = window
                        datePopoverTitle = nil
                        store.showFilterMenu = false
                    }
                }
                if store.chips.dateWindow != nil {
                    Divider().padding(.vertical, 4)
                    FilterMenuRow(icon: "xmark.circle", title: "Anytime") {
                        store.chips.dateWindow = nil
                        datePopoverTitle = nil
                        store.showFilterMenu = false
                    }
                }
            }
            .padding(8)
            .frame(width: 180)
        }
    }

    /// Editor pane for text filters (From/To/Cc/Bcc/Subject) and Labels.
    @ViewBuilder
    private func fieldEditor(_ field: FilterField) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button { editingField = nil } label: {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                Text(field.title).font(.system(size: 12, weight: .semibold))
                if field == .from || field == .label {
                    Menu(fieldExclude ? "does not contain" : "contains") {
                        Button("contains") { fieldExclude = false }
                        Button("does not contain") { fieldExclude = true }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if field == .label {
                Picker("", selection: $store.chips.labelId) {
                    Text("Any").tag(String?.none)
                    ForEach(allLabels, id: \.gmailLabelId) { label in
                        Text(label.name).tag(String?.some(label.gmailLabelId))
                    }
                }
                .labelsHidden()
                .onChange(of: store.chips.labelId) {
                    store.chips.labelName = allLabels.first { $0.gmailLabelId == store.chips.labelId }?.name
                    store.chips.labelExclude = fieldExclude
                }
            } else {
                TextField(field == .subject ? "Subject contains…" : "Name or address…",
                          text: $fieldDraft)
                    .onSubmit { apply(field) }
                if field == .from {
                    // Sender suggestions with favicons, Notion Mail-style.
                    ForEach(store.contactSuggestions(for: fieldDraft), id: \.email) { contact in
                        Button {
                            store.chips.senderContains = contact.email
                            store.chips.senderExclude = fieldExclude
                            store.showFilterMenu = false
                        } label: {
                            HStack(spacing: 6) {
                                FaviconView(email: contact.email)
                                (Text(contact.name.isEmpty ? contact.email : contact.name)
                                 + Text(contact.name.isEmpty ? "" : "  \(contact.email)")
                                    .foregroundColor(.secondary))
                                    .font(.system(size: 12)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    Spacer()
                    Button("Apply") { apply(field) }
                        .controlSize(.small)
                        .disabled(fieldDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(4)
    }

    private func beginEditing(_ field: FilterField) {
        switch field {
        case .from:
            fieldDraft = store.chips.senderContains
            fieldExclude = store.chips.senderExclude
        case .to: fieldDraft = store.chips.toContains
        case .cc: fieldDraft = store.chips.ccContains
        case .bcc: fieldDraft = store.chips.bccContains
        case .subject: fieldDraft = store.chips.subjectContains
        case .label: fieldExclude = store.chips.labelExclude
        }
        editingField = field
    }

    private func apply(_ field: FilterField) {
        let value = fieldDraft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        switch field {
        case .from:
            store.chips.senderContains = value
            store.chips.senderExclude = fieldExclude
        case .to: store.chips.toContains = value
        case .cc: store.chips.ccContains = value
        case .bcc: store.chips.bccContains = value
        case .subject: store.chips.subjectContains = value
        case .label: break
        }
        store.showFilterMenu = false
    }

    /// Mutate the chips and dismiss the popover.
    private func set(_ mutate: (inout FilterChips) -> Void) {
        mutate(&store.chips)
        store.showFilterMenu = false
    }

    private func showCategory(_ cat: String) {
        store.chips.category.show.insert(cat)
        store.chips.category.hide.remove(cat)
        store.showFilterMenu = false
    }

    private func hideCategory(_ cat: String) {
        store.chips.category.hide.insert(cat)
        store.chips.category.show.remove(cat)
        store.showFilterMenu = false
    }

    private func saveAsView() {
        var v = SavedView.empty()
        v.name = store.selectedView.title + " (filtered)"
        v.accountId = store.activeAccountId
        // Structured fields keep the ViewEditor form usable; chipsJSON captures
        // the FULL filter set (to/cc/bcc, subject, date, calendar, exclude
        // modes…) so the saved view is lossless.
        v.labelId = store.chips.labelId
        v.unreadOnly = store.chips.unreadOnly
        v.showArchived = store.chips.showArchived
        v.hasAttachmentOnly = store.chips.hasAttachmentOnly
        v.senderContains = store.chips.senderContains
        if store.chips.category.hide.isSuperset(of: ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL"]) {
            v.excludePromotions = true
        }
        if let cat = store.chips.category.show.first {
            v.category = cat
        }
        v.chipsJSON = try? JSONEncoder().encode(store.chips)
        store.showFilterMenu = false
        store.editingView = v
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
        .background(Color.notionAccent.opacity(0.2), in: Capsule())
    }

    private var lastSync: Date? {
        store.accounts.compactMap(\.lastSyncAt).min()
    }

    private var allLabels: [LabelRow] {
        let labels = store.labelsByAccount.values.flatMap { $0 }
        var seen = Set<String>()
        return labels.filter { seen.insert($0.gmailLabelId).inserted }.sorted { $0.name < $1.name }
    }

    /// A persistent toggle chip: highlighted while its filter is on.
    private func quickChip(_ title: String, icon: String, active: Bool,
                           toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            chipLabel(title, icon: icon, active: active)
        }
        .buttonStyle(.plain)
    }

    /// "Labels" dropdown chip: shows the active label filter, or opens a
    /// picker of all user labels.
    private var labelsChip: some View {
        Button {
            labelQuery = ""
            showLabelsPopover = true
        } label: {
            if let name = store.chips.labelName {
                // Active: show the label's own color as a leading dot.
                HStack(spacing: 4) {
                    Circle().fill(store.labelTint(anyAccount: name)).frame(width: 8, height: 8)
                    Text("\(store.chips.labelExclude ? "≠ " : "")\(name)").font(.caption)
                }
                .foregroundStyle(Color.notionAccent)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.notionAccent.opacity(0.16), in: Capsule())
            } else {
                chipLabel("Labels", icon: "tag", active: false)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showLabelsPopover, arrowEdge: .bottom) {
            labelsPopover
        }
    }

    /// The Labels chip dropdown: a searchable, color-dotted list of the user's
    /// labels, a clear action when a filter is active, and a shortcut into the
    /// organizer (colors + drag ordering).
    private var labelsPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            SearchField(prompt: "Search labels", text: $labelQuery, compact: true)

            if store.chips.labelName != nil {
                FilterMenuRow(icon: "xmark.circle", title: "Clear label filter") {
                    store.chips.labelId = nil
                    store.chips.labelName = nil
                    showLabelsPopover = false
                }
                Divider()
            }

            let matches = filteredLabels
            if allLabels.isEmpty {
                Text("No labels yet")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else if matches.isEmpty {
                Text("No labels match “\(labelQuery)”")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(matches, id: \.gmailLabelId) { label in
                            labelFilterRow(label)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            Divider()
            FilterMenuRow(icon: "slider.horizontal.3", title: "Organize labels…") {
                showLabelsPopover = false
                store.showLabelOrganizer = true
            }
        }
        .padding(10)
        .frame(width: 240)
    }

    /// One selectable label row: a colored dot, the name, and a check when it's
    /// the active filter.
    private func labelFilterRow(_ label: LabelRow) -> some View {
        let selected = store.chips.labelId == label.gmailLabelId
        let tint = store.labelTint(label.name, account: label.accountId)
        return Button {
            store.chips.labelId = label.gmailLabelId
            store.chips.labelName = label.name
            store.chips.labelExclude = false
            showLabelsPopover = false
        } label: {
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 9, height: 9)
                Text(label.name).font(.system(size: 12.5)).lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.notionAccent)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTint()
    }

    private var filteredLabels: [LabelRow] {
        let q = labelQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allLabels }
        return allLabels.filter { $0.name.lowercased().contains(q) }
    }

    private func chipLabel(_ title: String, icon: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption)
            Text(title).font(.caption)
        }
        // Notion Mail-style active chip: blue text on a blue-tinted pill.
        .foregroundStyle(active ? Color.notionAccent : Color.primary)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(active ? Color.notionAccent.opacity(0.16) : Color.secondary.opacity(0.1),
                    in: Capsule())
    }
}

/// Hover tint matching FilterMenuRow, for non-Button rows (the Date menus).
struct FilterRowHoverTint: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering ? Color.primary.opacity(0.07) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverTint() -> some View { modifier(FilterRowHoverTint()) }
}

/// One row of the Notion Mail-style filter menu: icon + title, hover tint,
/// with an optional trailing glyph (e.g. a chevron for rows that open a
/// submenu).
struct FilterMenuRow: View {
    let icon: String
    let title: String
    var trailing: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title).font(.system(size: 12.5))
                Spacer(minLength: 0)
                if let trailing {
                    Image(systemName: trailing)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(hovering ? Color.primary.opacity(0.07) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Sender favicon for filter suggestions: the domain's favicon, falling back
/// to a generic person glyph.
struct FaviconView: View {
    let email: String

    var body: some View {
        AsyncImage(url: faviconURL) { image in
            image.resizable()
        } placeholder: {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(width: 16, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var faviconURL: URL? {
        guard let domain = email.split(separator: "@").last, !domain.isEmpty else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=64")
    }
}

/// Dense Notion Mail-style single-line row:
/// [dot] participants   subject  snippet…………  [ai] [icons] time
struct ThreadRow: View {
    @EnvironmentObject var store: MailStore
    @AppStorage("fontScale") private var fontScale = 1.0
    let thread: MailThread
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(thread.isUnread ? Color.notionAccent : .clear)
                .frame(width: 7, height: 7)

            HStack(spacing: 4) {
                Text(participantsDisplay)
                    .font(.system(size: 14 * fontScale, weight: thread.isUnread ? .semibold : .regular))
                    .foregroundStyle(thread.isUnread ? Color.primary : Color.primary.opacity(0.65))
                    .lineLimit(1)
                if thread.messageCount > 1 {
                    Text("\(thread.messageCount)")
                        .font(.system(size: 11.5 * fontScale)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 168 * fontScale, alignment: .leading)

            (Text(thread.subject.isEmpty ? "(no subject)" : thread.subject.decodingHTMLEntities())
                .fontWeight(thread.isUnread ? .semibold : .medium)
                .foregroundColor(thread.isUnread ? .primary : .primary.opacity(0.65))
             + Text("  \(thread.snippet.decodingHTMLEntities())")
                .foregroundColor(.secondary))
                .font(.system(size: 14 * fontScale))
                .lineLimit(1)

            // On-device AI triage bucket, once the thread has been sorted.
            if let category = store.aiCategories[thread.id] {
                Text(category)
                    .font(.system(size: 10.5 * fontScale, weight: .medium))
                    .foregroundStyle(Color.aiCategory(category))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.aiCategory(category).opacity(0.14), in: Capsule())
                    .fixedSize()
            }

            Spacer(minLength: 8)

            // Fixed-height trailing area: icons overlay the timestamp on
            // hover so the row never changes size.
            ZStack(alignment: .trailing) {
                HStack(spacing: 5) {
                    // User labels as colored pills right before the date,
                    // Notion Mail-style.
                    ForEach(userLabels.prefix(2), id: \.self) { name in
                        labelPill(name)
                    }
                    if userLabels.count > 2 {
                        Text("+\(userLabels.count - 2)")
                            .font(.system(size: 11 * fontScale)).foregroundStyle(.secondary)
                    }
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
                    hoverButton("clock") { store.snoozingThread = thread }
                    hoverButton("trash") { store.trash(thread) }
                }
                .opacity(hovering ? 1 : 0)
            }
            .frame(height: 18 * fontScale)
        }
        .padding(.vertical, 3 * fontScale)
        .padding(.horizontal, 6)
        .background(hovering ? Color.primary.opacity(0.07) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, -6)
        // No contentShape here: it hijacks the List row's click handling on
        // macOS, so clicking a thread would no longer select/open it.
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private var participantsDisplay: String {
        thread.participants.isEmpty ? thread.fromDisplay : thread.participants
    }

    /// User-defined label names on this thread (system labels filtered out
    /// by the store, which only tracks type == "user" labels).
    private var userLabels: [String] {
        thread.labels
            .compactMap { store.labelName($0, account: thread.accountId) }
            .sorted()
    }

    /// Notion-style label pill: tinted text on a soft capsule of its color.
    private func labelPill(_ name: String) -> some View {
        let tint = store.labelTint(name, account: thread.accountId)
        return Text(name)
            .font(.system(size: 10.5 * fontScale, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 2.5)
            .background(tint.opacity(0.16), in: Capsule())
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
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.notionAccent.opacity(0.6)))
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
                    .toggleStyle(NotionCheckStyle())
                    .font(.system(size: 12))
                }
            }

            Divider()

            Button {
                filter.wrappedValue.show = []
                filter.wrappedValue.hide = []
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
