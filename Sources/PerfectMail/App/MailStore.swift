import Foundation
import SwiftUI
import AppKit
import GRDB

enum MailboxView: Hashable {
    case inbox          // unified inbox, minus Promotions/Social
    case promotions
    case social
    case starred
    case snoozed
    case labels         // all labeled mail, one section per label (Notion-style)
    case reminders
    case drafts
    case scheduled      // locally scheduled sends (not Gmail threads)
    case sent
    case allMail
    case trash
    case account(String)          // one account's inbox
    case label(account: String, labelId: String, name: String)
    case saved(Int64, String)     // custom view id + name

    var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .promotions: return "Promotions"
        case .social: return "Social"
        case .starred: return "Starred"
        case .snoozed: return "Snoozed"
        case .labels: return "Labels"
        case .reminders: return "Reminders"
        case .drafts: return "Drafts"
        case .scheduled: return "Scheduled"
        case .sent: return "Sent"
        case .allMail: return "All Mail"
        case .trash: return "Trash"
        case .account(let a): return a
        case .label(_, _, let name): return name
        case .saved(_, let name): return name
        }
    }

    /// Stable key for persisting per-view preferences (category picks).
    /// nil = the view doesn't persist them (saved views carry their own
    /// filters; scheduled isn't a mail list).
    var prefsKey: String? {
        switch self {
        case .inbox, .account: return "inbox"
        case .promotions: return "promotions"
        case .social: return "social"
        case .starred: return "starred"
        case .snoozed: return "snoozed"
        case .labels: return "labels"
        case .reminders: return "reminders"
        case .drafts: return "drafts"
        case .sent: return "sent"
        case .allMail: return "allMail"
        case .trash: return "trash"
        // Keyed per account: Gmail label IDs (Label_1, Label_2…) are only
        // unique within an account, so two accounts' labels must not share
        // a preference slot.
        case .label(let account, let labelId, _): return "label.\(account).\(labelId)"
        case .scheduled, .saved: return nil
        }
    }
}

/// Notion Mail-style category filter: a set of Gmail categories that the
/// inbox either must not contain (default) or must contain.
struct CategoryFilter: Equatable, Codable {
    var exclude = true                 // which set the Categories popover edits
    var show: Set<String> = []         // must contain any of these
    var hide: Set<String> = []         // must contain none of these

    static let names = [
        "CATEGORY_PROMOTIONS": "Promotions",
        "CATEGORY_SOCIAL": "Social",
        "CATEGORY_UPDATES": "Updates",
        "CATEGORY_FORUMS": "Forums",
    ]

    var isActive: Bool { !show.isEmpty || !hide.isEmpty }

    /// The set the Categories popover is currently editing.
    var categories: Set<String> {
        get { exclude ? hide : show }
        set { if exclude { hide = newValue } else { show = newValue } }
    }

    var title: String {
        guard isActive else { return "All" }
        var parts: [String] = []
        if !show.isEmpty {
            parts.append(show.map { Self.names[$0] ?? $0 }.sorted().joined(separator: ", "))
        }
        if !hide.isEmpty {
            parts.append("Not " + hide.map { Self.names[$0] ?? $0 }.sorted().joined(separator: ", "))
        }
        return parts.joined(separator: "; ")
    }
}

/// Relative received-date window for the filter bar.
enum DateWindow: Int, CaseIterable, Codable {
    case today = 1, week = 7, month = 30

    var title: String {
        switch self {
        case .today: return "Today"
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        }
    }
}

/// Transient filter chips layered on top of the current view (the bar above
/// the thread list). Reset when the view changes.
struct FilterChips: Equatable, Codable {
    var category = CategoryFilter()
    var unreadOnly = false
    var showArchived = false
    var labelId: String?
    var labelName: String?
    var labelExclude = false      // "does not contain" mode for the label
    var senderContains = ""
    var senderExclude = false     // "does not contain" mode for the sender
    /// Matches against message From headers (email address or "@domain"),
    /// unlike senderContains which matches display names. Optional so views
    /// saved before this field existed still decode. Powers "Split from Inbox".
    var fromEmailContains: String? = nil
    var hasAttachmentOnly = false
    var noAttachmentOnly = false
    var readOnly = false          // isUnread == false
    var showSent = false          // widen inbox to include SENT threads
    var toContains = ""
    var ccContains = ""
    var bccContains = ""
    var subjectContains = ""
    var dateWindow: DateWindow?   // received within the last N days
    var calendarOnly = false      // only threads with a calendar invite (.ics)
    var hideCalendar = false      // hide threads with a calendar invite

    /// Built-in factory default chips for a view (inbox hides
    /// Promotions/Social). Pure — never reads persisted state, so
    /// "changed vs default" comparisons and Clear all mean the factory
    /// default, and Clear all is always a way back to it.
    static func defaults(for view: MailboxView) -> FilterChips {
        var chips = FilterChips()
        switch view {
        case .inbox, .account:
            chips.category = CategoryFilter(
                exclude: true,
                hide: ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL"])
        default:
            break
        }
        return chips
    }

    /// What a view opens with: the factory defaults, plus the category pick
    /// the user made earlier (persisted per view) so it survives view
    /// switches and relaunch.
    static func initial(for view: MailboxView) -> FilterChips {
        var chips = defaults(for: view)
        if let saved = savedCategory(for: view) { chips.category = saved }
        return chips
    }

    static func savedCategory(for view: MailboxView) -> CategoryFilter? {
        guard let key = view.prefsKey,
              let data = UserDefaults.standard.data(forKey: "categoryFilter.\(key)")
        else { return nil }
        return try? JSONDecoder().decode(CategoryFilter.self, from: data)
    }

    static func saveCategory(_ category: CategoryFilter, for view: MailboxView) {
        guard let key = view.prefsKey,
              let data = try? JSONEncoder().encode(category) else { return }
        // Persisting the factory default is the same as having no pick;
        // drop the key so future built-in default changes reach the user.
        if category == defaults(for: view).category {
            UserDefaults.standard.removeObject(forKey: "categoryFilter.\(key)")
        } else {
            UserDefaults.standard.set(data, forKey: "categoryFilter.\(key)")
        }
    }
}

@MainActor
final class MailStore: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var labelsByAccount: [String: [LabelRow]] = [:]
    @Published var threads: [MailThread] = []
    @Published var savedViews: [SavedView] = []
    @Published var selectedView: MailboxView = .inbox {
        didSet { readStateKeepIds.removeAll() }
    }
    @Published var selectedThreadId: String?
    /// Gmail-style "?" cheat sheet.
    @Published var showShortcutsHelp = false
    /// User-rebindable single-key shortcuts (Settings → Keyboard shortcuts).
    let keyBindings = KeyBindings()
    @Published var searchText: String = ""
    /// Bumped by `/` (Gmail-style) to move keyboard focus into the sidebar
    /// search field. The sidebar watches this and drives its `@FocusState`.
    @Published var searchFocusToken = 0
    /// Recent search queries, newest first, shown under the search field while
    /// it has focus. Persisted so history survives relaunch.
    @Published var recentSearches: [String] =
        UserDefaults.standard.stringArray(forKey: "recentSearches") ?? []

    /// Remember a submitted/picked query: dedupe (case-insensitive), move to
    /// front, cap the list so the dropdown stays scannable.
    func recordSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        var list = recentSearches.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        list.insert(q, at: 0)
        recentSearches = Array(list.prefix(8))
        UserDefaults.standard.set(recentSearches, forKey: "recentSearches")
    }

    func removeRecentSearch(_ query: String) {
        recentSearches.removeAll { $0 == query }
        UserDefaults.standard.set(recentSearches, forKey: "recentSearches")
    }

    func clearRecentSearches() {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: "recentSearches")
    }
    @Published var chips = FilterChips.initial(for: .inbox) {
        // Category picks persist per view so they're back after relaunch.
        // Only user edits persist — programmatic resets (view switches) go
        // through resetChips() so built-in defaults never get frozen into
        // UserDefaults as if the user had chosen them.
        didSet {
            if !suppressChipPersistence, chips.category != oldValue.category {
                FilterChips.saveCategory(chips.category, for: selectedView)
            }
        }
    }
    private var suppressChipPersistence = false

    /// Reset the filter bar for the current view: factory defaults plus the
    /// user's persisted category pick. Doesn't count as a user edit.
    func resetChips() {
        suppressChipPersistence = true
        chips = FilterChips.initial(for: selectedView)
        suppressChipPersistence = false
    }
    @Published var activeAccountId: String?   // nil = all accounts (unified)
    @Published var syncStatus: String = ""
    @Published var lastError: String?
    @Published var composeRequest: ComposeRequest?
    @Published var undoAction: UndoAction?
    @Published var editingView: SavedView?
    @Published var editingAccountLabels = false
    @Published var showLabelPicker = false
    @Published var showLabelOrganizer = false
    @Published var snoozingThread: MailThread?   // custom snooze date sheet
    @Published var confirmingDraftDelete: MailThread?   // delete-draft confirmation alert
    // Arrow-key highlight for the label picker. Driven by the window-level
    // key monitor (the picker's text field eats arrow events before SwiftUI's
    // onKeyPress sees them); the view clamps it to the filtered list.
    @Published var labelPickerHighlight = 0
    // The picker's filter text lives here (not @State in the view) so the key
    // monitor can route typed characters in while the text field is still
    // winning the focus race — otherwise a fast second keystroke falls
    // through to the thread list's type-select.
    @Published var labelPickerQuery = "" {
        didSet { if labelPickerQuery != oldValue { labelPickerNavigated = false } }
    }
    // True once arrows moved the picker highlight; space then toggles the
    // highlighted label instead of typing into the filter. Typing resets it.
    var labelPickerNavigated = false
    @Published var showCommandPalette = false
    @Published var showFilterMenu = false   // "+ Filter" popover (Ctrl-F)
    @Published var unreadCounts: [String: Int] = [:]   // sidebar badges
    @Published var notice: String?                      // transient confirmation toast
    private var noticeTimer: Timer?

    func showNotice(_ text: String) {
        notice = text
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.notice = nil }
        }
    }

    // MARK: - On-device AI triage

    @Published var aiCategories: [String: String] = [:]   // threadId → category
    @Published var classifying = false
    private var aiCategoriesLoaded = false

    /// Loads the persisted category map once; after that the in-memory map is
    /// authoritative (classifyInbox updates it as it writes rows), so thread
    /// reloads don't re-read the table every time.
    func loadAICategories() {
        guard !aiCategoriesLoaded else { return }
        aiCategoriesLoaded = true
        let rows = (try? db.read { try ThreadAICategory.fetchAll($0) }) ?? []
        aiCategories = Dictionary(rows.map { ($0.threadId, $0.category) }) { _, last in last }
    }

    /// Classifies the currently loaded threads into local AI buckets. Manual
    /// and sequential (a small local model), skipping already-classified
    /// threads. Results persist in their own table so sync never wipes them.
    func classifyInbox() {
        guard !classifying else { return }
        let targets = threads.filter { aiCategories[$0.id] == nil }
        guard !targets.isEmpty else {
            showNotice("All caught up — nothing new to sort.")
            return
        }
        classify(targets, quiet: false)
    }

    /// Auto-triage: after each sync, quietly classify new inbox mail with the
    /// local model. Quiet on purpose — Ollama may simply not be running — and
    /// backs off ten minutes after a failure so a down server isn't retried
    /// on every 60-second sync tick.
    static let autoClassifyKey = "autoClassifyEnabled"
    private var autoClassifyPausedUntil: Date?

    func autoClassifyNewMail() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.autoClassifyKey) == nil
                || defaults.bool(forKey: Self.autoClassifyKey) else { return }
        if let pause = autoClassifyPausedUntil, pause > Date() { return }
        loadAICategories()
        let candidates = (try? db.read { db in
            try MailThread
                .filter(Column("inInbox") == true && Column("inTrash") == false)
                .order(Column("lastDate").desc).limit(100).fetchAll(db)
        }) ?? []
        classify(candidates.filter { aiCategories[$0.id] == nil }, quiet: true)
    }

    private func classify(_ targets: [MailThread], quiet: Bool) {
        guard !classifying, !targets.isEmpty else { return }
        classifying = true
        Task {
            var done = 0
            for thread in targets {
                let from = thread.participants.isEmpty ? thread.fromDisplay : thread.participants
                let prompt = Ollama.classify(subject: thread.subject, from: from,
                                             snippet: thread.snippet, categories: Classifier.categories)
                do {
                    let raw = try await Ollama.generate(prompt: prompt)
                    let category = Classifier.normalize(raw)
                    try? await db.write { database in
                        try ThreadAICategory(threadId: thread.id, category: category).save(database)
                    }
                    await MainActor.run {
                        aiCategories[thread.id] = category
                        done += 1
                        syncStatus = "Sorting with AI… \(done)/\(targets.count)"
                    }
                } catch {
                    await MainActor.run {
                        classifying = false
                        syncStatus = ""
                        if quiet {
                            autoClassifyPausedUntil = Date().addingTimeInterval(600)
                        } else {
                            showNotice(error.localizedDescription)
                        }
                    }
                    return
                }
            }
            await MainActor.run {
                classifying = false
                syncStatus = ""
                if !quiet {
                    showNotice("Sorted \(done) thread\(done == 1 ? "" : "s") with AI.")
                }
            }
        }
    }

    // MARK: - VIP senders

    /// Lowercased VIP addresses, and which loaded threads they sent. Kept in
    /// memory so the priority partition never queries per row.
    @Published private(set) var vipEmails: Set<String> = []
    @Published private(set) var vipThreadIds: Set<String> = []
    @Published private(set) var vipGroups: [String: String] = [:]
    @Published private(set) var vipGroupEnabled: [String: Bool] = [:]

    /// VIPs that actually count: members of a toggled-off group are paused.
    var activeVIPEmails: Set<String> {
        vipEmails.filter { vipGroupEnabled[vipGroups[$0] ?? ""] ?? true }
    }

    func loadVIPs() {
        let rows = (try? db.read { try VIPSender.fetchAll($0) }) ?? []
        vipEmails = Set(rows.map { $0.email.lowercased() })
        var groups: [String: String] = [:]
        for row in rows {
            if let groupName = row.groupName, !groupName.isEmpty {
                groups[row.email.lowercased()] = groupName
            }
        }
        vipGroups = groups
        let groupRows = (try? db.read { try VIPGroupRow.fetchAll($0) }) ?? []
        vipGroupEnabled = Dictionary(uniqueKeysWithValues: groupRows.map { ($0.name, $0.enabled) })
    }

    /// Group definitions persist in their own table so a group survives losing
    /// its last member; tag values still count for rows created before v14.
    private func ensureVIPGroup(_ name: String?, in db: GRDB.Database) throws {
        guard let name, !name.isEmpty else { return }
        if try VIPGroupRow.fetchOne(db, key: name) == nil {
            try VIPGroupRow(name: name).insert(db)
        }
    }

    func addVIP(_ email: String, group: String? = nil) {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard e.contains("@") else { return }
        try? db.write { db in
            try ensureVIPGroup(group, in: db)
            try VIPSender(email: e, groupName: group).save(db)
        }
        loadVIPs()
        reloadThreads()
        showNotice("\(e) added to VIPs")
    }

    /// Batch add (VIP manager paste box): one write, one reload, one notice.
    /// Returns how many were actually new.
    @discardableResult
    func addVIPs(_ emails: [String], group: String? = nil) -> Int {
        let fresh = Set(emails.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.contains("@") && !vipEmails.contains($0) })
        guard !fresh.isEmpty else { return 0 }
        try? db.write { db in
            try ensureVIPGroup(group, in: db)
            for e in fresh { try VIPSender(email: e, groupName: group).save(db) }
        }
        loadVIPs()
        reloadThreads()
        showNotice(fresh.count == 1 ? "\(fresh.first!) added to VIPs"
                                    : "\(fresh.count) senders added to VIPs")
        return fresh.count
    }

    func removeVIP(_ email: String) {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        try? db.write { _ = try VIPSender.deleteOne($0, key: e) }
        loadVIPs()
        reloadThreads()
    }

    func setVIPGroup(_ email: String, group: String?) {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        let g = (group ?? "").isEmpty ? nil : group
        try? db.write { db in
            try ensureVIPGroup(g, in: db)
            if var sender = try VIPSender.fetchOne(db, key: e) {
                sender.groupName = g
                try sender.update(db)
            }
        }
        loadVIPs()
        reloadThreads()
    }

    /// Pause/resume VIP status for a whole group.
    func setVIPGroupEnabled(_ name: String, _ enabled: Bool) {
        try? db.write { try VIPGroupRow(name: name, enabled: enabled).save($0) }
        loadVIPs()
        reloadThreads()
    }

    var allVIPGroupNames: [String] {
        Set(vipGroups.values).union(vipGroupEnabled.keys).sorted()
    }

    /// Newest sender address on a thread (for the Add/Remove VIP menu).
    func senderEmail(of thread: MailThread) -> String? {
        let header = (try? db.read { db in
            try String.fetchOne(db, sql: """
                SELECT fromHeader FROM message WHERE threadId = ?
                ORDER BY date DESC LIMIT 1
                """, arguments: [thread.id])
        }) ?? nil
        guard let header else { return nil }
        let email = MessageParser.emailAddress(header).lowercased()
        return email.contains("@") ? email : nil
    }

    /// Recomputes which of the loaded threads came from a VIP. One query per
    /// reload, none when the VIP list is empty.
    func refreshVIPThreadIds() {
        let active = activeVIPEmails
        guard !active.isEmpty, !threads.isEmpty else {
            if !vipThreadIds.isEmpty { vipThreadIds = [] }
            return
        }
        let ids = threads.map(\.id)
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let rows = (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT DISTINCT threadId, fromHeader FROM message
                WHERE threadId IN (\(placeholders))
                """, arguments: StatementArguments(ids))
        }) ?? []
        var hits = Set<String>()
        for row in rows {
            let header: String = row["fromHeader"]
            if active.contains(MessageParser.emailAddress(header).lowercased()) {
                hits.insert(row["threadId"])
            }
        }
        vipThreadIds = hits
    }

    // MARK: - Blocked senders

    /// Lowercased blocked addresses. Their threads move to Spam immediately
    /// on block and again after every sync (new arrivals).
    @Published private(set) var blockedEmails: Set<String> = []

    func loadBlocked() {
        let rows = (try? db.read { try BlockedSender.fetchAll($0) }) ?? []
        blockedEmails = Set(rows.map { $0.email.lowercased() })
    }

    func isBlocked(_ email: String) -> Bool {
        blockedEmails.contains(email.trimmingCharacters(in: .whitespaces).lowercased())
    }

    func blockSender(_ email: String) {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard e.contains("@") else { return }
        try? db.write { try BlockedSender(email: e).save($0) }
        loadBlocked()
        applyBlocklist()
        showNotice("Blocked \(e) — their mail goes to Spam")
    }

    func unblockSender(_ email: String) {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        try? db.write { _ = try BlockedSender.deleteOne($0, key: e) }
        loadBlocked()
        showNotice("Unblocked \(e)")
    }

    /// Moves every inbox thread from a blocked sender to Spam. Quiet (no
    /// per-thread undo toast — blocking is the undoable act, via Unblock).
    /// Runs on block and after each sync so new arrivals never linger.
    func applyBlocklist() {
        guard !blockedEmails.isEmpty else { return }
        let rows = (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT DISTINCT thread.id AS threadId, message.fromHeader AS fromHeader
                FROM thread JOIN message ON message.threadId = thread.id
                WHERE thread.inInbox = 1 AND thread.inTrash = 0
                """)
        }) ?? []
        var hitIds = Set<String>()
        for row in rows {
            let header: String = row["fromHeader"]
            if blockedEmails.contains(MessageParser.emailAddress(header).lowercased()) {
                hitIds.insert(row["threadId"])
            }
        }
        guard !hitIds.isEmpty else { return }
        let hits = (try? db.read { db in
            try MailThread.filter(hitIds.contains(Column("id"))).fetchAll(db)
        }) ?? []
        for thread in hits {
            mutateThread(thread) { $0.inInbox = false } remote: { client, id in
                try await client.modifyThread(id: id, add: ["SPAM"], remove: ["INBOX"])
            }
        }
    }

    /// User-facing label for an account ("Personal", "Fund", …).
    func renameAccount(_ id: String, label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        try? db.write { db in
            if var account = try Account.fetchOne(db, key: id) {
                account.displayName = trimmed.isEmpty ? id : trimmed
                try account.update(db)
            }
        }
        reloadAccounts()
    }

    /// Name recipients see on outgoing mail ("Ron Boger <ron@…>").
    func setSenderName(_ id: String, name: String) {
        try? db.write { db in
            if var account = try Account.fetchOne(db, key: id) {
                account.senderName = name.trimmingCharacters(in: .whitespaces)
                try account.update(db)
            }
        }
        reloadAccounts()
    }

    struct ComposeRequest: Identifiable {
        let id = UUID()
        let replyTo: Message?
        var replyAll = false
        var forward = false
        var editDraft: Message? = nil   // an existing Gmail draft being edited
        var restore: PendingSend? = nil // undone send: reopen with this content
        var prefillTo: String? = nil    // new mail straight to this address
    }

    struct UndoAction: Identifiable {
        let id = UUID()
        let label: String
        let undo: () -> Void
    }

    var selectedThread: MailThread? {
        threads.first { $0.id == selectedThreadId }
    }

    func setActiveAccount(_ id: String?) {
        activeAccountId = id
        selectedThreadId = nil
        readStateKeepIds.removeAll()
        reloadThreads()
    }

    private let db = AppDatabase.shared.dbQueue
    private var syncTimer: Timer?
    private var undoTimer: Timer?
    private var engines: [String: SyncEngine] = [:]
    private var clients: [String: GmailClient] = [:]
    private var knownUnreadInboxIds: Set<String> = []
    private var notifiedThreadIds: Set<String> = []
    // Threads whose read state changed while an unread/read filter was active.
    // They stay listed (so opening an unread thread doesn't yank it out from
    // under the reading pane) until the filter is dropped or the view changes.
    private var readStateKeepIds: Set<String> = []

    private var readStateFilterActive: Bool {
        if chips.unreadOnly || chips.readOnly { return true }
        if case .saved(let id, _) = selectedView,
           savedViews.first(where: { $0.id == id })?.unreadOnly == true { return true }
        return false
    }

    init() {
        reloadAccounts()
        reloadSavedViews()
        loadVIPs()
        loadBlocked()
        reloadThreads()
        reloadScheduledSends()
        // Anything that came due while the app was closed goes out now.
        Task { await self.fireDueScheduledSends() }
        knownUnreadInboxIds = currentUnreadInboxIds()
        notifiedThreadIds = knownUnreadInboxIds
        Notifier.requestPermission()
        startPolling()
        rebuildMetadataIfNeeded()
        rebuildContacts()
        seedDefaultSnippetsIfNeeded()
    }

    /// One-time seed of the starter snippets, so `/` in compose has something
    /// to show on a fresh install. Runs once (tracked in UserDefaults) and
    /// skips names that already exist, so it never fights an import or a delete.
    private func seedDefaultSnippetsIfNeeded() {
        let key = "didSeedDefaultSnippets"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let planned = SnippetImport.plan(SnippetDefaults.items,
                                         existingNames: snippets().map(\.name))
        try? db.write { db in
            for item in planned {
                var s = Snippet(id: nil, name: item.name, body: item.body,
                                movesToBcc: item.movesToBcc ?? false)
                try s.insert(db)
            }
        }
        UserDefaults.standard.set(true, forKey: key)
        if !planned.isEmpty { objectWillChange.send() }
    }

    // MARK: - Contacts (derived from synced mail; no extra Google scopes)

    struct Contact: Identifiable, Hashable {
        let name: String
        let email: String
        let weight: Int
        var id: String { email }
        var display: String { name.isEmpty ? email : "\(name) — \(email)" }
    }

    @Published private(set) var contacts: [Contact] = []

    func rebuildContacts() {
        let ownAddresses = Set(accounts.map { $0.id.lowercased() })
        Task {
            let rows = (try? await db.read { db -> [Row] in
                try Row.fetchAll(db, sql: "SELECT fromHeader, toHeader, ccHeader, labelIds FROM message")
            }) ?? []
            var weights: [String: (name: String, weight: Int)] = [:]
            for row in rows {
                let isSent = (row["labelIds"] as String).contains("SENT")
                for header in [row["fromHeader"] as String, row["toHeader"] as String, row["ccHeader"] as String] {
                    for piece in MessageParser.splitAddresses(header) {
                        let email = MessageParser.emailAddress(piece).lowercased()
                        guard email.contains("@"), !email.contains(" "),
                              !ownAddresses.contains(email) else { continue }
                        let name = MessageParser.displayName(fromHeader: piece)
                        // People you send to matter more than newsletter senders.
                        let add = isSent ? 5 : 1
                        let prev = weights[email] ?? ("", 0)
                        weights[email] = (prev.name.count >= name.count ? prev.name : name,
                                          prev.weight + add)
                    }
                }
            }
            let ranked = weights
                .map { Contact(name: $0.value.name == $0.key ? "" : $0.value.name,
                               email: $0.key, weight: $0.value.weight) }
                .sorted { $0.weight > $1.weight }
                .prefix(2000)
            await MainActor.run { self.contacts = Array(ranked) }
        }
    }

    /// Top matches for an address-field token.
    func contactSuggestions(for query: String) -> [Contact] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 1 else { return [] }
        return Array(contacts.lazy.filter {
            $0.email.contains(q) || $0.name.lowercased().contains(q)
        }.prefix(6))
    }

    func client(for accountId: String) -> GmailClient {
        if let c = clients[accountId] { return c }
        let c = GmailClient(accountEmail: accountId)
        clients[accountId] = c
        return c
    }

    /// One-time recompute of derived thread columns after the v2 migration.
    private func rebuildMetadataIfNeeded() {
        let key = "meta.rebuilt.v2"
        guard !UserDefaults.standard.bool(forKey: key), !accounts.isEmpty else { return }
        Task {
            for account in accounts {
                let engine = engines[account.id] ?? SyncEngine(accountId: account.id)
                engines[account.id] = engine
                try? await engine.rebuildAllThreadMetadata()
            }
            UserDefaults.standard.set(true, forKey: key)
            reloadThreads()
        }
    }

    // MARK: - Loading

    func reloadAccounts() {
        accounts = (try? db.read { try Account.order(Column("id")).fetchAll($0) }) ?? []
        // User order first (organizer drag), alphabetical among the unordered.
        let rows = (try? db.read {
            try LabelRow.filter(Column("type") == "user")
                .order(Column("sortOrder"), Column("name")).fetchAll($0)
        }) ?? []
        labelsByAccount = Dictionary(grouping: rows, by: \.accountId)
    }

    func reloadSavedViews() {
        savedViews = (try? db.read { try SavedView.order(Column("name")).fetchAll($0) }) ?? []
    }

    private static let categoryLabels = ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL"]

    /// Chip toggles arrive in bursts (typing a sender, flipping several
    /// filters); coalesce them into one reload instead of a full 300-thread
    /// query per change. View switches keep calling reloadThreads() directly.
    private var chipReloadTask: Task<Void, Never>?
    func reloadThreadsDebounced() {
        chipReloadTask?.cancel()
        chipReloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            self?.reloadThreads()
        }
    }

    func reloadThreads() {
        chipReloadTask?.cancel()   // a direct reload supersedes a pending debounced one
        let view = selectedView
        let search = searchText.trimmingCharacters(in: .whitespaces)
        let chips = chips
        let activeAccount = activeAccountId
        if !readStateFilterActive { readStateKeepIds.removeAll() }
        let keepIds = Array(readStateKeepIds)
        let allLabels = labelsByAccount.values.flatMap { $0 }
        threads = (try? db.read { [weak self] db -> [MailThread] in
            if !search.isEmpty {
                let parsed = SearchQuery.parse(search)
                var q = MailThread.all()
                if !parsed.text.isEmpty {
                    let ids = try Row.fetchAll(db, sql: """
                        SELECT DISTINCT message.threadId FROM message
                        JOIN message_fts ON message_fts.rowid = message.rowid
                        WHERE message_fts MATCH ?
                        """, arguments: [FTS5Pattern(matchingAllPrefixesIn: parsed.text)])
                        .map { $0["threadId"] as String }
                    q = q.filter(ids.contains(Column("id")))
                }
                if let from = parsed.from {
                    let pattern = "%\(from)%"
                    q = q.filter(sql: "(fromDisplay LIKE ? OR participants LIKE ?)",
                                 arguments: [pattern, pattern])
                }
                if let to = parsed.to {
                    // Recipient headers live on messages, so match via EXISTS.
                    q = q.filter(sql: """
                        EXISTS (SELECT 1 FROM message
                                WHERE message.threadId = thread.id
                                  AND (message.toHeader LIKE ? OR message.ccHeader LIKE ?
                                       OR message.bccHeader LIKE ?))
                        """, arguments: ["%\(to)%", "%\(to)%", "%\(to)%"])
                }
                if let subject = parsed.subject {
                    q = q.filter(sql: "subject LIKE ?", arguments: ["%\(subject)%"])
                }
                if let unread = parsed.unread {
                    q = q.filter(Column("isUnread") == unread)
                }
                if parsed.starred {
                    q = q.filter(Column("labelIds").like("%STARRED%"))
                }
                if let after = parsed.after {
                    q = q.filter(Column("lastDate") >= after)
                }
                if let before = parsed.before {
                    q = q.filter(Column("lastDate") < before)
                }
                for name in parsed.labels {
                    // A label name resolves to Gmail label ids (it can exist on
                    // several accounts); unknown names fall back to the raw
                    // token uppercased, which covers system labels (STARRED…).
                    var ids = allLabels
                        .filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                        .map(\.gmailLabelId)
                    if ids.isEmpty { ids = [name.uppercased()] }
                    let conditions = ids.map { _ in "labelIds LIKE ?" }.joined(separator: " OR ")
                    q = q.filter(sql: "(\(conditions))",
                                 arguments: StatementArguments(ids.map { "%\($0)%" }))
                }
                if parsed.hasAttachment { q = q.filter(Column("hasAttachment") == true) }
                if let activeAccount { q = q.filter(Column("accountId") == activeAccount) }
                return try q.order(Column("lastDate").desc).limit(200).fetchAll(db)
            }
            guard let self else { return [] }
            var q = Self.baseQuery(for: view, savedViews: self.savedViews, keepIds: keepIds)
            if chips.showArchived || chips.showSent {
                // Widen from inbox-only before layering the other chips.
                q = Self.widen(q, for: view, archived: chips.showArchived, sent: chips.showSent)
            }
            q = Self.applyChips(q, chips, keepIds: keepIds)
            if let activeAccount { q = q.filter(Column("accountId") == activeAccount) }
            return try q.order(Column("lastDate").desc).limit(300).fetchAll(db)
        }) ?? []
        loadAICategories()
        refreshVIPThreadIds()
        refreshCountsAndBadge()
    }

    // MARK: - Server-side search

    @Published var serverSearching = false

    /// Local search only covers cached mail (within the sync window). This
    /// pulls matching messages straight from Gmail so a search can reach older
    /// mail, then reloads. Gmail's query syntax matches the app's operators, so
    /// the raw search text is passed through as the query.
    func searchAllGmail() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !serverSearching else { return }
        serverSearching = true
        syncStatus = "Searching all mail…"
        let targets = activeAccountId.map { [$0] } ?? accounts.map(\.id)
        Task {
            for accountId in targets {
                let engine = engines[accountId] ?? SyncEngine(accountId: accountId)
                engines[accountId] = engine
                do {
                    try await engine.searchServer(query: query)
                } catch {
                    await MainActor.run { self.lastError = error.localizedDescription }
                }
            }
            await MainActor.run {
                serverSearching = false
                syncStatus = ""
                reloadThreads()
                rebuildContacts()
            }
        }
    }

    /// Layers the full FilterChips set onto a thread query. Shared by the live
    /// filter bar and by saved views (so "Save as view" is lossless). Does NOT
    /// apply the archived/sent *widening* (that's view-dependent) or account
    /// scoping (applied by the caller).
    /// `keepIds` are threads that must stay visible even if they no longer match
    /// the read-state chip (e.g. a thread you just marked read under an
    /// unread-only filter), so the row doesn't vanish under your cursor.
    static func applyChips(_ query: QueryInterfaceRequest<MailThread>, _ chips: FilterChips,
                           keepIds: [String] = []) -> QueryInterfaceRequest<MailThread> {
        var q = query
        for cat in chips.category.hide {
            q = q.filter(!Column("labelIds").like("%\(cat)%"))
        }
        if !chips.category.show.isEmpty {
            // Contains any of the selected categories (values bound, not interpolated).
            let conditions = chips.category.show
                .map { _ in "labelIds LIKE ?" }
                .joined(separator: " OR ")
            let patterns = chips.category.show.map { "%\($0)%" }
            q = q.filter(sql: conditions, arguments: StatementArguments(patterns))
        }
        if chips.unreadOnly { q = q.filter(Column("isUnread") == true || keepIds.contains(Column("id"))) }
        if chips.readOnly { q = q.filter(Column("isUnread") == false || keepIds.contains(Column("id"))) }
        if let labelId = chips.labelId {
            let match = Column("labelIds").like("%\(labelId)%")
            q = chips.labelExclude ? q.filter(!match) : q.filter(match)
        }
        if chips.hasAttachmentOnly { q = q.filter(Column("hasAttachment") == true) }
        if chips.noAttachmentOnly { q = q.filter(Column("hasAttachment") == false) }
        if !chips.senderContains.isEmpty {
            let pattern = "%\(chips.senderContains)%"
            let condition = "(fromDisplay LIKE ? OR participants LIKE ?)"
            q = q.filter(sql: chips.senderExclude ? "NOT \(condition)" : condition,
                         arguments: [pattern, pattern])
        }
        if let sender = chips.fromEmailContains, !sender.isEmpty {
            q = q.filter(sql: """
                EXISTS (SELECT 1 FROM message
                        WHERE message.threadId = thread.id AND message.fromHeader LIKE ?)
                """, arguments: ["%\(sender)%"])
        }
        for (header, value) in [("toHeader", chips.toContains),
                                ("ccHeader", chips.ccContains),
                                ("bccHeader", chips.bccContains)] where !value.isEmpty {
            q = q.filter(sql: """
                EXISTS (SELECT 1 FROM message
                        WHERE message.threadId = thread.id AND message.\(header) LIKE ?)
                """, arguments: ["%\(value)%"])
        }
        if !chips.subjectContains.isEmpty {
            q = q.filter(sql: "subject LIKE ?", arguments: ["%\(chips.subjectContains)%"])
        }
        if let window = chips.dateWindow {
            let cutoff = Calendar.current.startOfDay(
                for: Date().addingTimeInterval(Double(-(window.rawValue - 1)) * 86400))
            q = q.filter(Column("lastDate") >= cutoff)
        }
        if chips.calendarOnly || chips.hideCalendar {
            let invite = """
                EXISTS (SELECT 1 FROM message
                        JOIN attachment ON attachment.messageId = message.id
                        WHERE message.threadId = thread.id
                          AND (attachment.mimeType LIKE 'text/calendar%'
                               OR attachment.filename LIKE '%.ics'))
                """
            if chips.calendarOnly { q = q.filter(sql: invite) }
            if chips.hideCalendar { q = q.filter(sql: "NOT \(invite)") }
        }
        return q
    }

    private static func baseQuery(for view: MailboxView, savedViews: [SavedView],
                                  keepIds: [String] = []) -> QueryInterfaceRequest<MailThread> {
        var q = MailThread.all()
        let now = Date()
        func notSnoozed(_ q: QueryInterfaceRequest<MailThread>) -> QueryInterfaceRequest<MailThread> {
            q.filter(Column("snoozeUntil") == nil || Column("snoozeUntil") <= now)
        }
        switch view {
        case .inbox:
            // Category filtering is handled by the Categories chip.
            q = notSnoozed(q.filter(Column("inInbox") == true && Column("inTrash") == false))
        case .promotions:
            q = q.filter(Column("inTrash") == false && Column("labelIds").like("%CATEGORY_PROMOTIONS%"))
        case .social:
            q = q.filter(Column("inTrash") == false && Column("labelIds").like("%CATEGORY_SOCIAL%"))
        case .starred:
            q = q.filter(Column("isStarred") == true && Column("inTrash") == false)
        case .snoozed:
            q = q.filter(Column("snoozeUntil") != nil && Column("snoozeUntil") > now && Column("inTrash") == false)
        case .labels:
            // Any user label (Gmail user label ids are "Label_<n>"); system
            // labels (INBOX, SENT, CATEGORY_*) never match.
            q = q.filter(Column("inTrash") == false && Column("labelIds").like("%Label_%"))
        case .reminders:
            q = q.filter(Column("reminderAt") != nil)
        case .drafts:
            q = q.filter(Column("labelIds").like("%DRAFT%") && Column("inTrash") == false)
        case .scheduled:
            // Scheduled sends aren't threads; ScheduledListView renders them.
            q = q.none()
        case .sent:
            q = q.filter(Column("labelIds").like("%SENT%") && Column("inTrash") == false)
        case .allMail:
            q = q.filter(Column("inTrash") == false)
        case .trash:
            q = q.filter(Column("inTrash") == true)
        case .account(let a):
            q = notSnoozed(q.filter(Column("accountId") == a && Column("inInbox") == true && Column("inTrash") == false))
        case .label(let a, let labelId, _):
            q = q.filter(Column("accountId") == a && Column("labelIds").like("%\(labelId)%"))
        case .saved(let id, _):
            guard let v = savedViews.first(where: { $0.id == id }) else { break }
            q = q.filter(Column("inTrash") == false)
            // Lossless path: a "Save as view" snapshot carries the full chip
            // set as JSON. Apply the base (inbox unless archived) + account
            // scope, then layer every chip dimension via the shared helper.
            if let chips = v.chipsJSON.flatMap({ try? JSONDecoder().decode(FilterChips.self, from: $0) }) {
                if !chips.showArchived { q = notSnoozed(q.filter(Column("inInbox") == true)) }
                if let a = v.accountId { q = q.filter(Column("accountId") == a) }
                if v.starredOnly { q = q.filter(Column("isStarred") == true) }
                q = applyChips(q, chips, keepIds: keepIds)
                break
            }
            // Legacy path: views built in the ViewEditor form (structured fields).
            if !v.showArchived { q = notSnoozed(q.filter(Column("inInbox") == true)) }
            if let a = v.accountId { q = q.filter(Column("accountId") == a) }
            if let label = v.labelId { q = q.filter(Column("labelIds").like("%\(label)%")) }
            if v.unreadOnly { q = q.filter(Column("isUnread") == true || keepIds.contains(Column("id"))) }
            if v.starredOnly { q = q.filter(Column("isStarred") == true) }
            if v.hasAttachmentOnly { q = q.filter(Column("hasAttachment") == true) }
            if !v.senderContains.isEmpty {
                q = q.filter(Column("fromDisplay").like("%\(v.senderContains)%")
                             || Column("participants").like("%\(v.senderContains)%"))
            }
            if v.excludePromotions {
                for cat in categoryLabels { q = q.filter(!Column("labelIds").like("%\(cat)%")) }
            }
            if let cat = v.category { q = q.filter(Column("labelIds").like("%\(cat)%")) }
        }
        return q
    }

    private static func widen(_ q: QueryInterfaceRequest<MailThread>, for view: MailboxView,
                              archived: Bool, sent: Bool) -> QueryInterfaceRequest<MailThread> {
        // Rebuild without the inbox constraint for views where it applies.
        // "Show archived" widens to everything not trashed; "Show sent" alone
        // widens to inbox-or-sent. (Category chips are layered on afterwards.)
        func widened(_ w: QueryInterfaceRequest<MailThread>) -> QueryInterfaceRequest<MailThread> {
            if archived { return w }
            return w.filter(Column("inInbox") == true || Column("labelIds").like("%SENT%"))
        }
        switch view {
        case .inbox:
            return widened(MailThread.filter(Column("inTrash") == false))
        case .account(let a):
            return widened(MailThread.filter(Column("accountId") == a && Column("inTrash") == false))
        default:
            return q
        }
    }

    /// What the dock badge counts. Stored in UserDefaults ("badgeScope"):
    /// every account, the inbox currently focused in the sidebar, or one
    /// specific account ("account:<email>").
    enum BadgeScope: RawRepresentable, Hashable {
        case all
        case focused
        case account(String)

        init?(rawValue: String) {
            switch rawValue {
            case "all": self = .all
            case "focused": self = .focused
            default:
                guard rawValue.hasPrefix("account:") else { return nil }
                self = .account(String(rawValue.dropFirst("account:".count)))
            }
        }

        var rawValue: String {
            switch self {
            case .all: return "all"
            case .focused: return "focused"
            case .account(let id): return "account:\(id)"
            }
        }
    }

    static var badgeScope: BadgeScope {
        get {
            UserDefaults.standard.string(forKey: "badgeScope")
                .flatMap(BadgeScope.init(rawValue:)) ?? .all
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "badgeScope") }
    }

    /// Recompute the sidebar counts and dock badge (e.g. after the badge
    /// scope changes in Settings).
    func refreshBadge() { refreshCountsAndBadge() }

    private func refreshCountsAndBadge() {
        // Local counts (fallback + reminders, which Gmail doesn't know about).
        let activeAccount = activeAccountId
        // The account the badge counts: nil = every account. "Focused"
        // follows the sidebar (unified view = every account).
        let badgeAccount: String? = {
            switch Self.badgeScope {
            case .all: return nil
            case .focused: return activeAccount
            case .account(let id): return id
            }
        }()
        let (local, badgeTotal): ([String: Int], Int) = (try? db.read { db in
            func count(_ q: QueryInterfaceRequest<MailThread>,
                       scopedTo account: String?) -> Int {
                var q = q
                if let a = account { q = q.filter(Column("accountId") == a) }
                return (try? q.fetchCount(db)) ?? 0
            }
            func count(_ q: QueryInterfaceRequest<MailThread>) -> Int {
                count(q, scopedTo: activeAccount)
            }
            let unread = MailThread.filter(Column("isUnread") == true && Column("inTrash") == false)
            var inboxUnread = unread.filter(Column("inInbox") == true)
            for cat in Self.categoryLabels {
                inboxUnread = inboxUnread.filter(!Column("labelIds").like("%\(cat)%"))
            }
            let inboxLocal = count(inboxUnread)
            let counts = [
                "inbox": inboxLocal,
                "promotions": count(unread.filter(Column("labelIds").like("%CATEGORY_PROMOTIONS%"))),
                "social": count(unread.filter(Column("labelIds").like("%CATEGORY_SOCIAL%"))),
                "reminders": count(MailThread.filter(Column("reminderAt") != nil)),
                // Totals (not unread), matching each view's query exactly.
                "starred": count(MailThread.filter(
                    Column("isStarred") == true && Column("inTrash") == false)),
                "snoozed": count(MailThread.filter(
                    Column("snoozeUntil") != nil && Column("snoozeUntil") > Date()
                        && Column("inTrash") == false)),
                "drafts": count(MailThread.filter(
                    Column("labelIds").like("%DRAFT%") && Column("inTrash") == false)),
            ]
            // Same scope as the sidebar inbox count → reuse it.
            let badge = badgeAccount == activeAccount
                ? inboxLocal : count(inboxUnread, scopedTo: badgeAccount)
            return (counts, badge)
        }) ?? ([:], 0)

        var counts = local
        // Inbox badge always uses the local count: it applies the exact same
        // filter as the visible inbox list, so badge and list can't disagree.
        // (Gmail's INBOX-minus-categories math undercounts: CATEGORY_* label
        // totals include archived unread, so the difference can clamp to 0
        // while unread mail is visibly in the inbox.)
        // Gmail's numbers are still authoritative for the category labels.
        let scoped = activeAccountId.map { id in apiCounts.filter { $0.key == id } } ?? apiCounts
        if !scoped.isEmpty {
            counts["promotions"] = scoped.values.reduce(0) { $0 + ($1["CATEGORY_PROMOTIONS"] ?? 0) }
            counts["social"] = scoped.values.reduce(0) { $0 + ($1["CATEGORY_SOCIAL"] ?? 0) }
        }
        unreadCounts = counts
        Notifier.setBadge(badgeTotal)
    }

    func messages(inThread threadId: String) -> [Message] {
        (try? db.read {
            try Message.filter(Column("threadId") == threadId).order(Column("date")).fetchAll($0)
        }) ?? []
    }

    func attachments(for messageId: String) -> [AttachmentRow] {
        (try? db.read {
            try AttachmentRow.filter(Column("messageId") == messageId).fetchAll($0)
        }) ?? []
    }

    // MARK: - Saved views

    func saveView(_ view: SavedView) {
        var v = view
        // If this is a lossless (chips-backed) view, fold any edits made to the
        // ViewEditor's structured fields back into the JSON so chipsJSON stays
        // authoritative and form edits still take effect.
        if var chips = v.chipsJSON.flatMap({ try? JSONDecoder().decode(FilterChips.self, from: $0) }) {
            chips.labelId = v.labelId
            chips.unreadOnly = v.unreadOnly
            chips.showArchived = v.showArchived
            chips.hasAttachmentOnly = v.hasAttachmentOnly
            chips.senderContains = v.senderContains
            if v.excludePromotions {
                chips.category.hide.formUnion(["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL"])
            }
            if let cat = v.category { chips.category.show = [cat] }
            v.chipsJSON = try? JSONEncoder().encode(chips)
        }
        try? db.write { db in
            var toSave = v
            try toSave.save(db)
        }
        reloadSavedViews()
    }

    /// Notion Mail-style "Split from Inbox": a new saved view holding all
    /// mail whose From header matches `sender` (an address, or "@domain"),
    /// then jump straight into it.
    func splitFromInbox(matching sender: String, named name: String) {
        var chips = FilterChips()
        chips.fromEmailContains = sender
        chips.showArchived = true   // the view is their full history, not inbox-only
        var view = SavedView.empty()
        view.name = name
        view.showArchived = true    // saveView folds this back into the chips
        view.chipsJSON = try? JSONEncoder().encode(chips)
        saveView(view)
        if let saved = savedViews.last(where: { $0.name == name }), let id = saved.id {
            selectedView = .saved(id, name)
        }
        showNotice("New view: \(name)")
    }

    func deleteView(_ view: SavedView) {
        guard let id = view.id else { return }
        try? db.write { db in _ = try SavedView.deleteOne(db, key: id) }
        if case .saved(let selectedId, _) = selectedView, selectedId == id {
            selectedView = .inbox
        }
        reloadSavedViews()
    }

    // MARK: - Account lifecycle

    func addAccount() {
        Task {
            do {
                let (refresh, access) = try await OAuthService().signIn()
                var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
                req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
                struct UserInfo: Decodable { let email: String; let name: String? }
                let (data, _) = try await URLSession.shared.data(for: req)
                let info = try JSONDecoder().decode(UserInfo.self, from: data)

                try Keychain.set(refresh, forKey: "refreshToken.\(info.email)")
                let account = Account(id: info.email, displayName: info.name ?? info.email,
                                      historyId: nil, lastSyncAt: nil,
                                      senderName: info.name ?? "")
                try await db.write { db in try account.save(db) }
                reloadAccounts()
                await sync(accountId: info.email)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func removeAccount(_ id: String) {
        Keychain.delete("refreshToken.\(id)")
        try? db.write { db in _ = try Account.deleteOne(db, key: id) }
        engines[id] = nil
        clients[id] = nil
        reloadAccounts()
        reloadThreads()
    }

    // MARK: - Sync

    func startPolling() {
        fireDueSnoozes()  // catch snoozes that came due while the app was closed
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.syncAll()
                self?.fireDueReminders()
                self?.fireDueSnoozes()
                // Backstop for the one-shot timer (sleep/wake can eat it).
                await self?.fireDueScheduledSends()
            }
        }
    }

    func syncAll() async {
        for account in accounts { await sync(accountId: account.id) }
        applyBlocklist()
        notifyNewMail()
        rebuildContacts()
        autoClassifyNewMail()
    }

    func sync(accountId: String) async {
        let engine = engines[accountId] ?? SyncEngine(accountId: accountId)
        engines[accountId] = engine
        syncStatus = "Syncing \(accountId)…"
        do {
            try await engine.syncNow { status in
                Task { @MainActor [weak self] in self?.syncStatus = status }
            }
            syncStatus = ""
            await refreshApiCounts(accountId: accountId)
            await backfillSenderNameIfNeeded(accountId: accountId)
            reloadAccounts()
            reloadThreads()
        } catch {
            syncStatus = ""
            lastError = "\(accountId): \(error.localizedDescription)"
        }
    }

    /// Gmail's own unread counts, so the sidebar matches gmail.com exactly.
    private var apiCounts: [String: [String: Int]] = [:]   // account → label → threadsUnread

    /// Accounts added before senderName existed get it from the profile.
    private func backfillSenderNameIfNeeded(accountId: String) async {
        guard var account = accounts.first(where: { $0.id == accountId }),
              account.senderName.isEmpty,
              let name = try? await client(for: accountId).userName(),
              !name.isEmpty else { return }
        account.senderName = name
        let updated = account
        try? await db.write { db in try updated.update(db) }
    }

    /// RFC 2822 From value: "Ron Boger <ron@x.com>" when a name is known.
    func fromHeader(for accountId: String) -> String {
        guard let account = accounts.first(where: { $0.id == accountId }),
              !account.senderName.isEmpty else { return accountId }
        return "\(account.senderName) <\(accountId)>"
    }

    private func refreshApiCounts(accountId: String) async {
        let client = client(for: accountId)
        var counts: [String: Int] = [:]
        for label in ["INBOX", "CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL"] {
            if let info = try? await client.labelInfo(label) {
                counts[label] = info.threadsUnread ?? 0
            }
        }
        apiCounts[accountId] = counts
    }

    // MARK: - New-mail notifications

    private func currentUnreadInboxIds() -> Set<String> {
        Set((try? db.read { db -> [String] in
            var q = MailThread.filter(Column("isUnread") == true && Column("inInbox") == true && Column("inTrash") == false)
            for cat in Self.categoryLabels { q = q.filter(!Column("labelIds").like("%\(cat)%")) }
            return try q.fetchAll(db).map(\.id)
        }) ?? [])
    }

    private func notifyNewMail() {
        let current = currentUnreadInboxIds()
        let fresh = current.subtracting(notifiedThreadIds)
        notifiedThreadIds.formUnion(current)
        knownUnreadInboxIds = current
        guard !fresh.isEmpty else { return }
        let newThreads = (try? db.read { db in
            try MailThread.filter(fresh.contains(Column("id"))).order(Column("lastDate").desc).fetchAll(db)
        }) ?? []
        for thread in newThreads.prefix(3) {
            Notifier.notify(title: thread.fromDisplay,
                            body: thread.subject.isEmpty ? thread.snippet : thread.subject,
                            id: "mail.\(thread.id)")
        }
        if newThreads.count > 3 {
            Notifier.notify(title: "PerfectMail", body: "\(newThreads.count) new messages", id: "mail.batch")
        }
    }

    // MARK: - Reminders

    func setReminder(_ thread: MailThread, after days: Int?) {
        var copy = thread
        let when = days.map { Calendar.current.date(byAdding: .day, value: $0, to: Date())! }
        copy.reminderAt = when
        // Snapshot the thread's current activity so the reminder can cancel
        // itself if a newer message arrives ("remind if no reply").
        copy.reminderSetAt = when == nil ? nil : Date()
        let updated = copy
        try? db.write { db in try updated.save(db) }
        reloadThreads()
    }

    private func fireDueReminders() {
        let due = (try? db.read { db in
            try MailThread.filter(Column("reminderAt") != nil && Column("reminderAt") <= Date()).fetchAll(db)
        }) ?? []
        var changed = false
        for thread in due {
            changed = true
            var copy = thread
            copy.reminderAt = nil
            copy.reminderSetAt = nil
            // "Remind if no reply": if the thread advanced after the reminder
            // was set (a reply or any new message), the nudge is moot — clear
            // it silently instead of firing.
            let replied = thread.reminderSetAt.map { thread.lastDate > $0 } ?? false
            if !replied {
                Notifier.notify(title: "Follow up: \(thread.fromDisplay)",
                                body: thread.subject.isEmpty ? thread.snippet : thread.subject,
                                id: "reminder.\(thread.id)")
            }
            let updated = copy
            try? db.write { db in try updated.save(db) }
        }
        if changed { reloadThreads() }
    }

    // MARK: - Keyboard shortcuts

    private var pendingGoKey: Date?

    /// Returns true if the key was handled. Gmail-style single keys,
    /// including "g then …" navigation (g-i inbox, g-t sent, g-d drafts…).
    func handleKey(_ chars: String) -> Bool {
        if let started = pendingGoKey, Date().timeIntervalSince(started) < 1.5 {
            pendingGoKey = nil
            switch chars {
            case "i": selectedView = .inbox; return true
            case "s": selectedView = .starred; return true
            case "t": selectedView = .sent; return true
            case "d": selectedView = .drafts; return true
            case "a": selectedView = .allMail; return true
            case "p": selectedView = .promotions; return true
            default: break   // fall through to normal handling
            }
        }
        switch chars {
        case "g": pendingGoKey = Date(); return true
        case "?": showShortcutsHelp.toggle(); return true
        default: break
        }
        guard let command = keyBindings.command(for: chars) else { return false }
        perform(command)
        return true
    }

    /// Runs a rebindable single-key command. Kept separate from handleKey so
    /// the key→command mapping is the only thing the registry owns.
    func perform(_ command: ShortcutCommand) {
        switch command {
        case .archive: selectedThread.map(archive)
        case .trash: selectedThread.map(trash)
        case .toggleStar: selectedThread.map(toggleStar)
        case .toggleRead: if let t = selectedThread { setRead(t, read: t.isUnread) }
        case .snooze: if let t = selectedThread { snoozingThread = t }
        case .next: moveSelection(1)
        case .prev: moveSelection(-1)
        case .reply: if let t = selectedThread {
                         composeRequest = ComposeRequest(replyTo: messages(inThread: t.id).last)
                     }
        case .replyAll: if let t = selectedThread {
                            composeRequest = ComposeRequest(replyTo: messages(inThread: t.id).last, replyAll: true)
                        }
        case .forward: if let t = selectedThread {
                           composeRequest = ComposeRequest(replyTo: messages(inThread: t.id).last, forward: true)
                       }
        case .label: if selectedThread != nil {
                         labelPickerHighlight = 0
                         labelPickerQuery = ""
                         labelPickerNavigated = false
                         showLabelPicker = true
                     }
        case .undo: if let undo = undoAction { undo.undo() }
        case .compose: composeRequest = ComposeRequest(replyTo: nil)
        }
    }

    /// Gmail's `/`: move keyboard focus into the sidebar search field. Bumps a
    /// token instead of holding focus state directly so a repeated `/` (after
    /// the user clicked away) re-focuses.
    func focusSearch() {
        searchFocusToken &+= 1
    }

    // MARK: - Labels on threads

    /// User labels available for a thread's account.
    func userLabels(forAccount accountId: String) -> [LabelRow] {
        labelsByAccount[accountId] ?? []
    }

    /// The picker's filtered list for a thread — shared by LabelPicker (rows)
    /// and the window key monitor (space-to-toggle), so both always agree on
    /// which label is highlighted. Matching is per whitespace token, using
    /// locale-aware case/diacritic-insensitive comparison.
    func labelPickerLabels(for thread: MailThread) -> [LabelRow] {
        let labels = userLabels(forAccount: thread.accountId)
        let tokens = labelPickerQuery.split(separator: " ")
        guard !tokens.isEmpty else { return labels }
        return labels.filter { label in
            tokens.allSatisfy { label.name.localizedStandardContains($0) }
        }
    }

    /// The "Create <query>" row's label name: the trimmed query, when it
    /// wouldn't duplicate an existing label on the thread's account.
    func labelPickerCreateName(for thread: MailThread) -> String? {
        let name = labelPickerQuery.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let exists = userLabels(forAccount: thread.accountId)
            .contains { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        return exists ? nil : name
    }

    /// Creates the label on the thread's account, then applies it. The new
    /// label lands highlighted in the (re-emptied) picker list so the applied
    /// checkmark is visible.
    func createLabelAndApply(name: String, thread: MailThread) {
        let accountId = thread.accountId
        let client = client(for: accountId)
        Task {
            do {
                let l = try await client.createLabel(name: name)
                await MainActor.run {
                    try? self.db.write { db in
                        try LabelRow(id: "\(accountId):\(l.id)", accountId: accountId,
                                     gmailLabelId: l.id, name: l.name, type: l.type ?? "user",
                                     color: l.color?.backgroundColor).save(db)
                    }
                    self.reloadAccounts()
                    self.labelPickerQuery = ""
                    if let idx = self.userLabels(forAccount: accountId)
                        .firstIndex(where: { $0.gmailLabelId == l.id }) {
                        self.labelPickerHighlight = idx
                    }
                    self.toggleLabel(thread, labelId: l.id)
                }
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
        }
    }

    /// When the query matches a label that only exists on a *different*
    /// account, name it so the miss isn't silent (labels apply per account).
    func labelPickerOtherAccountMatch(excluding accountId: String) -> LabelRow? {
        let tokens = labelPickerQuery.split(separator: " ")
        guard !tokens.isEmpty, accounts.count > 1 else { return nil }
        let localNames = Set(userLabels(forAccount: accountId).map { $0.name.lowercased() })
        return labelsByAccount
            .filter { $0.key != accountId }
            .values.flatMap { $0 }
            .first { label in
                !localNames.contains(label.name.lowercased())
                    && tokens.allSatisfy { label.name.localizedStandardContains($0) }
            }
    }

    func labelName(_ labelId: String, account accountId: String) -> String? {
        labelsByAccount[accountId]?.first { $0.gmailLabelId == labelId }?.name
    }

    /// Display color for a label within an account: the user-assigned (or
    /// Gmail-seeded) color, falling back to the name-stable palette. Scoped by
    /// account so two accounts' same-named labels can carry different colors.
    func labelTint(_ name: String, account accountId: String) -> Color {
        let hex = labelsByAccount[accountId]?.first { $0.name == name }?.color
        return hex.flatMap(Color.hexString) ?? Color.stable(for: name)
    }

    /// Tint for a label filter that isn't scoped to one account (the Labels
    /// chip in unified mode): the color of any account's label with that name,
    /// else the name-stable fallback.
    func labelTint(anyAccount name: String) -> Color {
        let hex = labelsByAccount.values.lazy.flatMap { $0 }.first { $0.name == name }?.color
        return hex.flatMap(Color.hexString) ?? Color.stable(for: name)
    }

    /// Sets (or clears, with nil) a label's display color.
    func setLabelColor(_ label: LabelRow, hex: String?) {
        try? db.write { db in
            var row = label
            row.color = hex
            try row.save(db)
        }
        reloadAccounts()
    }

    /// Persists a drag-reorder of one account's labels from the organizer.
    func reorderLabels(account accountId: String, from source: IndexSet, to destination: Int) {
        var labels = labelsByAccount[accountId] ?? []
        labels.move(fromOffsets: source, toOffset: destination)
        try? db.write { db in
            for (idx, var row) in labels.enumerated() {
                row.sortOrder = idx
                try row.save(db)
            }
        }
        reloadAccounts()
    }

    func toggleLabel(_ thread: MailThread, labelId: String) {
        let has = thread.labels.contains(labelId)
        mutateThread(thread) { t in
            var labels = Set(t.labelIds.split(separator: " ").map(String.init))
            if has { labels.remove(labelId) } else { labels.insert(labelId) }
            t.labelIds = labels.sorted().joined(separator: " ")
        } remote: { client, id in
            try await client.modifyThread(id: id, add: has ? [] : [labelId],
                                          remove: has ? [labelId] : [])
        }
    }

    /// Set right before a keyboard-driven selection change (j/k, arrows) so
    /// the UI can keep the reading pane closed while browsing; a mouse click
    /// (which never sets it) reopens the pane. Cleared after each change.
    var selectionViaKeyboard = false

    /// Thread ids in the order the list actually displays them (priority
    /// section first, then grouped) — kept in sync by ThreadListView so
    /// keyboard navigation matches what's on screen.
    var displayOrder: [String] = []

    func moveSelection(_ delta: Int) {
        let order = displayOrder.isEmpty ? threads.map(\.id) : displayOrder
        guard !order.isEmpty else { return }
        let idx = order.firstIndex { $0 == selectedThreadId } ?? (delta > 0 ? -1 : 0)
        let next = min(max(idx + delta, 0), order.count - 1)
        selectedThreadId = order[next]
    }

    static func snoozeDate(hour: Int, addDays: Int = 0) -> Date {
        let cal = Calendar.current
        let base = cal.date(byAdding: .day, value: addDays, to: Date())!
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: base)!
    }

    // MARK: - Actions (optimistic local write, then remote, then resync on failure)

    private func mutateThread(_ thread: MailThread,
                              local: (inout MailThread) -> Void,
                              remote: @escaping (GmailClient, String) async throws -> Void) {
        var copy = thread
        local(&copy)
        let updated = copy
        try? db.write { db in try updated.save(db) }
        reloadThreads()
        let client = client(for: thread.accountId)
        let gmailThreadId = thread.gmailThreadId
        Task {
            do { try await remote(client, gmailThreadId) }
            catch {
                await MainActor.run { self.lastError = error.localizedDescription }
                await self.sync(accountId: thread.accountId)
            }
        }
    }

    private func offerUndo(_ label: String, undo: @escaping () -> Void) {
        undoAction = UndoAction(label: label, undo: undo)
        undoTimer?.invalidate()
        undoTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.undoAction = nil }
        }
    }

    /// Gmail-style auto-advance: after archiving/trashing/spamming the
    /// selected thread, land on the neighbor computed before the mutation —
    /// but only if the row actually left the list (e.g. not when a "show
    /// archived" chip keeps it visible).
    private func advanceSelection(after thread: MailThread, wasSelected: Bool, neighbor: String?) {
        guard wasSelected, let neighbor,
              !threads.contains(where: { $0.id == thread.id }),
              threads.contains(where: { $0.id == neighbor }) else { return }
        selectionViaKeyboard = true
        selectedThreadId = neighbor
    }

    func archive(_ thread: MailThread) {
        let wasSelected = selectedThreadId == thread.id
        let neighbor = SelectionAdvance.neighborId(in: threads.map(\.id), removing: thread.id)
        mutateThread(thread) { $0.inInbox = false } remote: { client, id in
            try await client.modifyThread(id: id, remove: ["INBOX"])
        }
        advanceSelection(after: thread, wasSelected: wasSelected, neighbor: neighbor)
        offerUndo("Archived") { [weak self] in
            guard let self else { return }
            self.mutateThread(thread) { $0.inInbox = true } remote: { client, id in
                try await client.modifyThread(id: id, add: ["INBOX"])
            }
            self.undoAction = nil
        }
    }

    /// Gmail moves the whole thread to Spam; it leaves the inbox locally
    /// right away and the next sync drops it from All Mail views too.
    func markSpam(_ thread: MailThread) {
        let wasSelected = selectedThreadId == thread.id
        let neighbor = SelectionAdvance.neighborId(in: threads.map(\.id), removing: thread.id)
        mutateThread(thread) { $0.inInbox = false } remote: { client, id in
            try await client.modifyThread(id: id, add: ["SPAM"], remove: ["INBOX"])
        }
        advanceSelection(after: thread, wasSelected: wasSelected, neighbor: neighbor)
        offerUndo("Marked as spam") { [weak self] in
            guard let self else { return }
            self.mutateThread(thread) { $0.inInbox = true } remote: { client, id in
                try await client.modifyThread(id: id, add: ["INBOX"], remove: ["SPAM"])
            }
            self.undoAction = nil
        }
    }

    func trash(_ thread: MailThread) {
        // Gmail-style auto-advance: when the selected thread is trashed, land
        // on the next conversation down (or the one above if it was last)
        // instead of leaving nothing selected. Computed before the mutation
        // removes the row from `threads`.
        let wasSelected = selectedThreadId == thread.id
        let neighbor = SelectionAdvance.neighborId(in: threads.map(\.id), removing: thread.id)
        mutateThread(thread) { $0.inTrash = true; $0.inInbox = false } remote: { client, id in
            try await client.trashThread(id: id)
        }
        advanceSelection(after: thread, wasSelected: wasSelected, neighbor: neighbor)
        offerUndo("Moved to Trash") { [weak self] in
            guard let self else { return }
            self.mutateThread(thread) { $0.inTrash = false; $0.inInbox = true } remote: { client, id in
                try await client.modifyThread(id: id, add: ["INBOX"], remove: ["TRASH"])
            }
            self.undoAction = nil
        }
    }

    func toggleStar(_ thread: MailThread) {
        let starring = !thread.isStarred
        mutateThread(thread) { $0.isStarred = starring } remote: { client, id in
            try await client.modifyThread(id: id, add: starring ? ["STARRED"] : [],
                                          remove: starring ? [] : ["STARRED"])
        }
    }

    func setRead(_ thread: MailThread, read: Bool) {
        if readStateFilterActive { readStateKeepIds.insert(thread.id) }
        mutateThread(thread) { $0.isUnread = !read } remote: { client, id in
            try await client.modifyThread(id: id, add: read ? [] : ["UNREAD"],
                                          remove: read ? ["UNREAD"] : [])
        }
    }

    /// Snooze mirrors what Gmail's own snooze looks like over the API: the
    /// thread loses INBOX while sleeping and gets it back when the date
    /// passes (or on unsnooze), so other Gmail clients agree with us.
    /// `snoozeUntil` itself stays local — the API has no snooze field —
    /// which also means threads snoozed *in* Gmail arrive here as archived
    /// and reappear on sync when Gmail wakes them.
    func snooze(_ thread: MailThread, until date: Date?) {
        guard let date else {  // unsnooze: back to the inbox now
            mutateThread(thread) { $0.snoozeUntil = nil; $0.inInbox = true } remote: { client, id in
                try await client.modifyThread(id: id, add: ["INBOX"])
            }
            return
        }
        let wasSelected = selectedThreadId == thread.id
        let neighbor = SelectionAdvance.neighborId(in: threads.map(\.id), removing: thread.id)
        mutateThread(thread) { $0.snoozeUntil = date; $0.inInbox = false } remote: { client, id in
            try await client.modifyThread(id: id, remove: ["INBOX"])
        }
        advanceSelection(after: thread, wasSelected: wasSelected, neighbor: neighbor)
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInTomorrow(date) ? "'tomorrow' h a" : "MMM d, h a"
        offerUndo("Snoozed until \(formatter.string(from: date))") { [weak self] in
            guard let self else { return }
            self.snooze(thread, until: nil)
            self.undoAction = nil
        }
    }

    /// Wakes snoozed threads whose date has passed: clears the snooze and
    /// restores INBOX (locally and on Gmail). Runs on the sync tick.
    private func fireDueSnoozes() {
        let now = Date()
        let due = (try? db.read { db in
            try MailThread
                .filter(Column("snoozeUntil") != nil && Column("snoozeUntil") <= now)
                .fetchAll(db)
        }) ?? []
        for thread in due { snooze(thread, until: nil) }
    }

    // MARK: - Sending

    /// A composed message waiting out the undo-send window.
    struct PendingSend {
        let accountId: String
        let to: String
        let cc: String
        let bcc: String
        let subject: String
        let body: String
        let replyTo: Message?
        let forward: Bool
        let attachments: [MIMEBuilder.Attachment]
        let replacingDraft: Message?
    }

    @Published private(set) var pendingSend: PendingSend?
    private var pendingSendTimer: Timer?
    static let undoSendWindow: TimeInterval = 10

    /// Queue a message: it actually sends after `undoSendWindow` unless undone.
    func queueSend(_ pending: PendingSend) {
        // A second send flushes the first immediately — one window at a time.
        if let previous = takePendingSend() {
            Task { await self.performSend(previous) }
        }
        pendingSend = pending
        undoTimer?.invalidate()
        undoAction = UndoAction(label: "Sending…") { [weak self] in self?.cancelPendingSend() }
        pendingSendTimer = Timer.scheduledTimer(withTimeInterval: Self.undoSendWindow,
                                                repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.flushPendingSend() }
        }
    }

    /// Undo: pull the message back into compose, nothing sent.
    func cancelPendingSend() {
        guard let p = takePendingSend() else { return }
        undoAction = nil
        composeRequest = ComposeRequest(replyTo: p.replyTo, forward: p.forward,
                                        editDraft: p.replacingDraft, restore: p)
    }

    /// Send the queued message now (window elapsed, or the app is quitting).
    func flushPendingSend() async {
        guard let p = takePendingSend() else { return }
        undoAction = nil
        await performSend(p)
    }

    private func takePendingSend() -> PendingSend? {
        pendingSendTimer?.invalidate()
        pendingSendTimer = nil
        defer { pendingSend = nil }
        return pendingSend
    }

    private func performSend(_ p: PendingSend) async {
        do {
            try await send(from: p.accountId, to: p.to, cc: p.cc, bcc: p.bcc,
                           subject: p.subject, body: p.body, replyTo: p.replyTo,
                           forward: p.forward,
                           attachments: p.attachments, replacingDraft: p.replacingDraft)
            showNotice("Sent")
        } catch {
            // Bring the message back so nothing is lost.
            lastError = "Send failed: \(error.localizedDescription)"
            composeRequest = ComposeRequest(replyTo: p.replyTo, forward: p.forward,
                                            editDraft: p.replacingDraft, restore: p)
        }
    }

    // MARK: - Scheduled sends (send later)

    @Published private(set) var scheduledSends: [ScheduledSend] = []
    private var scheduledSendTimer: Timer?

    func reloadScheduledSends() {
        scheduledSends = (try? db.read {
            try ScheduledSend.order(Column("sendAt")).fetchAll($0)
        }) ?? []
        armScheduledSendTimer()
    }

    /// Persist a composed message to go out at `date`. Survives relaunch;
    /// anything overdue sends on next launch.
    func scheduleSend(_ p: PendingSend, at date: Date) {
        let row = ScheduledSend(
            id: nil, accountId: p.accountId, toHeader: p.to, ccHeader: p.cc,
            bccHeader: p.bcc, subject: p.subject, body: p.body, sendAt: date,
            replyToMessageId: p.replyTo?.id, forward: p.forward,
            replacingDraftId: p.replacingDraft?.id,
            attachmentsJSON: ScheduledSend.encodeAttachments(p.attachments),
            createdAt: Date())
        try? db.write { db in try row.insert(db) }
        reloadScheduledSends()
        showNotice("Scheduled — sends \(SendSchedule.describe(date))")
    }

    /// Pull a scheduled message back into compose (nothing is lost).
    func editScheduledSend(_ s: ScheduledSend) {
        let p = pendingSend(from: s)
        try? db.write { db in _ = try ScheduledSend.deleteOne(db, key: s.id) }
        reloadScheduledSends()
        composeRequest = ComposeRequest(replyTo: p.replyTo, forward: p.forward,
                                        editDraft: p.replacingDraft, restore: p)
    }

    /// Skip the wait: goes through the normal undo-send window.
    func sendScheduledNow(_ s: ScheduledSend) {
        let p = pendingSend(from: s)
        try? db.write { db in _ = try ScheduledSend.deleteOne(db, key: s.id) }
        reloadScheduledSends()
        queueSend(p)
    }

    func discardScheduledSend(_ s: ScheduledSend) {
        try? db.write { db in _ = try ScheduledSend.deleteOne(db, key: s.id) }
        reloadScheduledSends()
        showNotice("Scheduled message discarded")
    }

    private func pendingSend(from s: ScheduledSend) -> PendingSend {
        // The referenced messages may have been pruned since; threading
        // headers then simply fall away.
        let replyTo = s.replyToMessageId.flatMap { id in
            (try? db.read { try Message.fetchOne($0, key: id) }) ?? nil
        }
        let draft = s.replacingDraftId.flatMap { id in
            (try? db.read { try Message.fetchOne($0, key: id) }) ?? nil
        }
        return PendingSend(accountId: s.accountId, to: s.toHeader, cc: s.ccHeader,
                           bcc: s.bccHeader, subject: s.subject, body: s.body,
                           replyTo: replyTo, forward: s.forward,
                           attachments: s.attachments, replacingDraft: draft)
    }

    private func armScheduledSendTimer() {
        scheduledSendTimer?.invalidate()
        scheduledSendTimer = nil
        guard let next = scheduledSends.map(\.sendAt).min() else { return }
        scheduledSendTimer = Timer.scheduledTimer(withTimeInterval: max(next.timeIntervalSinceNow, 1),
                                                  repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.fireDueScheduledSends() }
        }
    }

    func fireDueScheduledSends() async {
        let due = scheduledSends.filter { $0.sendAt <= Date() }
        guard !due.isEmpty else { return }
        for s in due {
            let p = pendingSend(from: s)
            _ = try? await db.write { db in try ScheduledSend.deleteOne(db, key: s.id) }
            await performSend(p)
            Notifier.notify(title: "Scheduled message sent",
                            body: s.subject.isEmpty ? s.toHeader : s.subject,
                            id: "scheduled.\(s.id ?? 0)")
        }
        reloadScheduledSends()
    }

    func send(from accountId: String, to: String, cc: String, bcc: String = "", subject: String,
              body: String, replyTo message: Message? = nil, forward: Bool = false,
              attachments: [MIMEBuilder.Attachment] = [],
              replacingDraft draft: Message? = nil) async throws {
        // For a forward, `message` is the forwarded original: it supplies the
        // HTML body below, but must not thread the send into its conversation.
        let threadParent = forward ? nil : message
        let bodyHTML = htmlAlternative(body: body, forwardOf: forward ? message : nil,
                                       draft: draft)
        let raw = MIMEBuilder.build(
            from: fromHeader(for: accountId), to: to, cc: cc, bcc: bcc, subject: subject,
            bodyText: body, bodyHTML: bodyHTML,
            inReplyTo: threadParent?.messageIdHeader,
            references: threadParent?.referencesHeader ?? draft?.referencesHeader,
            attachments: attachments
        )
        // A reply keeps its thread; so does a draft that lives in one.
        let gmailThreadId = (threadParent ?? draft).map { String($0.threadId.split(separator: ":").last!) }
        try await client(for: accountId).send(raw: raw, threadId: gmailThreadId)
        if let draft { await deleteUnderlyingDraft(draft, silent: true) }
        await sync(accountId: accountId)
    }

    /// The HTML alternative an outgoing message can carry without ever
    /// diverging from its plain text: a forward whose quoted block is
    /// untouched (the user's text goes on top of the original HTML), or a
    /// draft re-saved/sent with its body unedited (its stored HTML still
    /// matches). Nil means plain text only.
    private func htmlAlternative(body: String, forwardOf original: Message?,
                                 draft: Message?) -> String? {
        if let orig = original, let html = orig.bodyHTML, !html.isEmpty {
            let block = ForwardComposer.forwardBlock(
                fromHeader: orig.fromHeader, date: orig.date, subject: orig.subject,
                toHeader: orig.toHeader, ccHeader: orig.ccHeader, bodyText: orig.bodyText)
            if let userText = ForwardComposer.userText(inBody: body, expectedBlock: block) {
                return ForwardComposer.htmlBody(
                    userText: userText, fromHeader: orig.fromHeader, date: orig.date,
                    subject: orig.subject, toHeader: orig.toHeader, ccHeader: orig.ccHeader,
                    originalHTML: html)
            }
        }
        if let draft, let html = draft.bodyHTML, !html.isEmpty, body == draft.bodyText {
            return html
        }
        return nil
    }

    /// Saves compose state as a real Gmail draft (shows up in Gmail too).
    /// Replaces `replacing` when re-saving an edited draft.
    func saveDraft(from accountId: String, to: String, cc: String, bcc: String = "", subject: String,
                   body: String, replyTo message: Message? = nil, forward: Bool = false,
                   attachments: [MIMEBuilder.Attachment] = [],
                   replacing draft: Message? = nil) async {
        // Same rules as send(): a forward's original doesn't thread the
        // draft, but supplies the HTML body when the quote is untouched.
        let threadParent = forward ? nil : message
        let raw = MIMEBuilder.build(
            from: fromHeader(for: accountId), to: to, cc: cc, bcc: bcc, subject: subject, bodyText: body,
            bodyHTML: htmlAlternative(body: body, forwardOf: forward ? message : nil, draft: draft),
            inReplyTo: threadParent?.messageIdHeader,
            references: threadParent?.referencesHeader ?? draft?.referencesHeader,
            attachments: attachments
        )
        let gmailThreadId = ((threadParent ?? draft).map { String($0.threadId.split(separator: ":").last!) })
        do {
            try await client(for: accountId).createDraft(raw: raw, threadId: gmailThreadId)
            if let draft { await deleteUnderlyingDraft(draft, silent: true) }
            showNotice("Draft saved — find it in Drafts")
            await sync(accountId: accountId)
        } catch {
            lastError = "Draft not saved: \(error.localizedDescription)"
        }
    }

    // MARK: - Draft management

    /// A thread that is nothing but an unsent draft — opening it should hop
    /// straight into compose (Notion Mail-style), not the reading pane.
    /// Draft replies inside real conversations still open the thread.
    func isDraftOnly(_ thread: MailThread) -> Bool {
        guard thread.labels.contains("DRAFT") else { return false }
        let msgs = messages(inThread: thread.id)
        return !msgs.isEmpty && msgs.allSatisfy { $0.labelIds.contains("DRAFT") }
    }

    /// Opens an existing draft back into compose.
    func editDraft(inThread thread: MailThread) {
        if let draft = messages(inThread: thread.id).last(where: { $0.labelIds.contains("DRAFT") }) {
            composeRequest = ComposeRequest(replyTo: nil, editDraft: draft)
        }
    }

    /// Deletes the Gmail draft behind a local draft message.
    func deleteUnderlyingDraft(_ draftMessage: Message, silent: Bool = false) async {
        do {
            let client = client(for: draftMessage.accountId)
            let drafts = try await client.listDrafts()
            guard let match = drafts.first(where: { $0.message.id == draftMessage.gmailId }) else {
                return
            }
            try await client.deleteDraft(id: match.id)
            if !silent {
                showNotice("Draft deleted")
                await sync(accountId: draftMessage.accountId)
            }
        } catch {
            if !silent { lastError = error.localizedDescription }
        }
    }

    func deleteDraft(inThread thread: MailThread) {
        guard let draft = messages(inThread: thread.id).last(where: { $0.labelIds.contains("DRAFT") }) else { return }
        Task { await deleteUnderlyingDraft(draft) }
    }

    /// Download every attachment on a message into a folder the user picks.
    func saveAllAttachments(_ attachments: [AttachmentRow], message: Message) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save \(attachments.count) Attachments Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        Task {
            do {
                for att in attachments {
                    let data = try await client(for: message.accountId)
                        .getAttachment(messageId: message.gmailId, attachmentId: att.gmailAttachmentId)
                    let dest = dir.appendingPathComponent(MessageParser.safeFilename(att.filename))
                    try data.write(to: dest)
                    Self.markQuarantined(dest)
                }
                await MainActor.run {
                    showNotice("Saved \(attachments.count) attachments")
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
        }
    }

    // MARK: - Attachments

    /// Downloads a message's attachments as sendable MIME parts — used to
    /// carry the original files along on a forward, like Gmail does.
    func loadAttachments(for message: Message) async throws -> [MIMEBuilder.Attachment] {
        var out: [MIMEBuilder.Attachment] = []
        for att in attachments(for: message.id) {
            let data = try await client(for: message.accountId)
                .getAttachment(messageId: message.gmailId, attachmentId: att.gmailAttachmentId)
            out.append(.init(filename: MessageParser.safeFilename(att.filename),
                             mimeType: att.mimeType, data: data))
        }
        return out
    }

    /// Opens in the default app via a private temp file inside the sandbox
    /// (macOS purges it; nothing is written to user folders). The file is
    /// namespaced by message id (so same-named attachments never collide) and
    /// tagged with the quarantine attribute so Gatekeeper still gates it.
    /// Downloads an attachment into the per-message temp folder, reusing an
    /// already-downloaded copy so open → Quick Look → open doesn't re-fetch.
    private func attachmentTempURL(_ attachment: AttachmentRow, message: Message) async throws -> URL {
        // Keyed by attachment row too, so two same-named attachments on one
        // message can't serve each other's cached bytes.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerfectMailAttachments", isDirectory: true)
            .appendingPathComponent(MessageParser.safeFilename(message.gmailId), isDirectory: true)
            .appendingPathComponent(String(attachment.id ?? 0), isDirectory: true)
        let url = dir.appendingPathComponent(MessageParser.safeFilename(attachment.filename))
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let data = try await client(for: message.accountId)
            .getAttachment(messageId: message.gmailId, attachmentId: attachment.gmailAttachmentId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url)
        Self.markQuarantined(url)
        return url
    }

    func openAttachment(_ attachment: AttachmentRow, message: Message) {
        Task {
            do {
                let url = try await attachmentTempURL(attachment, message: message)
                NSWorkspace.shared.open(url)
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }

    /// Native Quick Look on an attachment (same sanitized, quarantined temp
    /// copy the Open path uses — no separate download).
    func quickLookAttachment(_ attachment: AttachmentRow, message: Message) {
        Task {
            do {
                let url = try await attachmentTempURL(attachment, message: message)
                QuickLookController.shared.show([url])
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }

    /// Tags a written-out attachment with `com.apple.quarantine`. The flags
    /// deliberately omit the "user approved" bit, so an email attachment still
    /// triggers Gatekeeper's "downloaded from the Internet" first-open warning
    /// and any handling app's own web-content checks. Best-effort.
    static func markQuarantined(_ url: URL) {
        let stamp = String(format: "%08x", UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970)))
        let value = "0001;\(stamp);PerfectMail;\(UUID().uuidString)"
        value.withCString { cstr in
            _ = setxattr(url.path, "com.apple.quarantine", cstr, strlen(cstr), 0, 0)
        }
    }

    /// Save As… — the user picks the destination via the system save panel,
    /// which is the only place outside the sandbox the app can write.
    func saveAttachment(_ attachment: AttachmentRow, message: Message) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MessageParser.safeFilename(attachment.filename)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                let data = try await client(for: message.accountId)
                    .getAttachment(messageId: message.gmailId, attachmentId: attachment.gmailAttachmentId)
                try data.write(to: destination)
                Self.markQuarantined(destination)
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
        }
    }

    // MARK: - Snippets

    func snippets() -> [Snippet] {
        (try? db.read { try Snippet.order(Column("name")).fetchAll($0) }) ?? []
    }

    func saveSnippet(name: String, body: String, movesToBcc: Bool = false) {
        try? db.write { db in
            var s = Snippet(id: nil, name: name, body: body, movesToBcc: movesToBcc)
            try s.insert(db)
        }
        objectWillChange.send()
    }

    func deleteSnippet(_ s: Snippet) {
        try? db.write { db in _ = try Snippet.deleteOne(db, key: s.id) }
        objectWillChange.send()
    }

    func updateSnippet(_ s: Snippet) {
        try? db.write { db in try s.update(db) }
        objectWillChange.send()
    }

    /// Imports snippets from a JSON file (`[{"name", "body", "movesToBcc"}]`),
    /// skipping any whose name already exists so re-importing is harmless.
    func importSnippets(from url: URL) throws -> (added: Int, skipped: Int) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let items = try SnippetImport.decode(Data(contentsOf: url))
        let planned = SnippetImport.plan(items, existingNames: snippets().map(\.name))
        try db.write { db in
            for item in planned {
                var s = Snippet(id: nil, name: item.name.trimmingCharacters(in: .whitespaces),
                                body: item.body, movesToBcc: item.movesToBcc ?? false)
                try s.insert(db)
            }
        }
        objectWillChange.send()
        return (planned.count, items.count - planned.count)
    }
}
