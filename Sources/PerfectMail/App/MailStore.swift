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
    case reminders
    case drafts
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
        case .reminders: return "Reminders"
        case .drafts: return "Drafts"
        case .sent: return "Sent"
        case .allMail: return "All Mail"
        case .trash: return "Trash"
        case .account(let a): return a
        case .label(_, _, let name): return name
        case .saved(_, let name): return name
        }
    }
}

/// Notion Mail-style category filter: a set of Gmail categories that the
/// inbox either must not contain (default) or must contain.
struct CategoryFilter: Equatable {
    var exclude = true                 // true = "do not contain"
    var categories: Set<String> = []   // empty = no category filtering

    static let names = [
        "CATEGORY_PROMOTIONS": "Promotions",
        "CATEGORY_SOCIAL": "Social",
        "CATEGORY_UPDATES": "Updates",
        "CATEGORY_FORUMS": "Forums",
    ]

    var isActive: Bool { !categories.isEmpty }

    var title: String {
        guard isActive else { return "All" }
        let list = categories.map { Self.names[$0] ?? $0 }.sorted().joined(separator: ", ")
        return exclude ? "Not \(list)" : list
    }
}

/// Transient filter chips layered on top of the current view (the bar above
/// the thread list). Reset when the view changes.
struct FilterChips: Equatable {
    var category = CategoryFilter()
    var unreadOnly = false
    var showArchived = false
    var labelId: String?
    var labelName: String?
    var senderContains = ""
    var hasAttachmentOnly = false

    /// Default chips for a given view (inbox hides Promotions/Social).
    static func defaults(for view: MailboxView) -> FilterChips {
        var chips = FilterChips()
        switch view {
        case .inbox, .account:
            chips.category = CategoryFilter(
                exclude: true,
                categories: ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL"])
        default:
            break
        }
        return chips
    }
}

@MainActor
final class MailStore: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var labelsByAccount: [String: [LabelRow]] = [:]
    @Published var threads: [MailThread] = []
    @Published var savedViews: [SavedView] = []
    @Published var selectedView: MailboxView = .inbox
    @Published var selectedThreadId: String?
    @Published var searchText: String = ""
    @Published var chips = FilterChips.defaults(for: .inbox)
    @Published var activeAccountId: String?   // nil = all accounts (unified)
    @Published var syncStatus: String = ""
    @Published var lastError: String?
    @Published var composeRequest: ComposeRequest?
    @Published var undoAction: UndoAction?
    @Published var editingView: SavedView?
    @Published var editingAccountLabels = false
    @Published var showCommandPalette = false
    @Published var unreadCounts: [String: Int] = [:]   // sidebar badges

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

    struct ComposeRequest: Identifiable {
        let id = UUID()
        let replyTo: Message?
        var aiIntent: String? = nil
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
        reloadThreads()
    }

    private let db = AppDatabase.shared.dbQueue
    private var syncTimer: Timer?
    private var undoTimer: Timer?
    private var engines: [String: SyncEngine] = [:]
    private var clients: [String: GmailClient] = [:]
    private var knownUnreadInboxIds: Set<String> = []
    private var notifiedThreadIds: Set<String> = []

    init() {
        reloadAccounts()
        reloadSavedViews()
        reloadThreads()
        knownUnreadInboxIds = currentUnreadInboxIds()
        notifiedThreadIds = knownUnreadInboxIds
        Notifier.requestPermission()
        startPolling()
        rebuildMetadataIfNeeded()
        rebuildContacts()
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
        labelsByAccount = Dictionary(grouping: (try? db.read {
            try LabelRow.filter(Column("type") == "user").order(Column("name")).fetchAll($0)
        }) ?? [], by: \.accountId)
    }

    func reloadSavedViews() {
        savedViews = (try? db.read { try SavedView.order(Column("name")).fetchAll($0) }) ?? []
    }

    private static let categoryLabels = ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL"]

    func reloadThreads() {
        let view = selectedView
        let search = searchText.trimmingCharacters(in: .whitespaces)
        let chips = chips
        let activeAccount = activeAccountId
        threads = (try? db.read { [weak self] db -> [MailThread] in
            if !search.isEmpty {
                let ids = try Row.fetchAll(db, sql: """
                    SELECT DISTINCT message.threadId FROM message
                    JOIN message_fts ON message_fts.rowid = message.rowid
                    WHERE message_fts MATCH ?
                    """, arguments: [FTS5Pattern(matchingAllPrefixesIn: search)])
                    .map { $0["threadId"] as String }
                var q = MailThread.filter(ids.contains(Column("id")))
                if let activeAccount { q = q.filter(Column("accountId") == activeAccount) }
                return try q.order(Column("lastDate").desc).limit(200).fetchAll(db)
            }
            guard let self else { return [] }
            var q = Self.baseQuery(for: view, savedViews: self.savedViews)
            // Layer transient chips on top.
            if chips.category.isActive {
                if chips.category.exclude {
                    for cat in chips.category.categories {
                        q = q.filter(!Column("labelIds").like("%\(cat)%"))
                    }
                } else {
                    // Contains any of the selected categories.
                    let conditions = chips.category.categories
                        .map { "labelIds LIKE '%\($0)%'" }
                        .joined(separator: " OR ")
                    q = q.filter(sql: conditions)
                }
            }
            if chips.unreadOnly { q = q.filter(Column("isUnread") == true) }
            if chips.showArchived {
                // Widen from inbox-only to everything not trashed.
                q = Self.widenArchived(q, for: view)
            }
            if let labelId = chips.labelId {
                q = q.filter(Column("labelIds").like("%\(labelId)%"))
            }
            if chips.hasAttachmentOnly { q = q.filter(Column("hasAttachment") == true) }
            if !chips.senderContains.isEmpty {
                q = q.filter(Column("fromDisplay").like("%\(chips.senderContains)%")
                             || Column("participants").like("%\(chips.senderContains)%"))
            }
            if let activeAccount { q = q.filter(Column("accountId") == activeAccount) }
            return try q.order(Column("lastDate").desc).limit(300).fetchAll(db)
        }) ?? []
        refreshCountsAndBadge()
    }

    private static func baseQuery(for view: MailboxView, savedViews: [SavedView]) -> QueryInterfaceRequest<MailThread> {
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
            q = q.filter(Column("snoozeUntil") != nil && Column("snoozeUntil") > now)
        case .reminders:
            q = q.filter(Column("reminderAt") != nil)
        case .drafts:
            q = q.filter(Column("labelIds").like("%DRAFT%") && Column("inTrash") == false)
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
            if !v.showArchived { q = notSnoozed(q.filter(Column("inInbox") == true)) }
            if let a = v.accountId { q = q.filter(Column("accountId") == a) }
            if let label = v.labelId { q = q.filter(Column("labelIds").like("%\(label)%")) }
            if v.unreadOnly { q = q.filter(Column("isUnread") == true) }
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

    private static func widenArchived(_ q: QueryInterfaceRequest<MailThread>, for view: MailboxView) -> QueryInterfaceRequest<MailThread> {
        // Rebuild without the inbox constraint for views where it applies.
        switch view {
        case .inbox:
            var w = MailThread.filter(Column("inTrash") == false)
            for cat in categoryLabels { w = w.filter(!Column("labelIds").like("%\(cat)%")) }
            return w
        case .account(let a):
            return MailThread.filter(Column("accountId") == a && Column("inTrash") == false)
        default:
            return q
        }
    }

    private func refreshCountsAndBadge() {
        let counts: [String: Int] = (try? db.read { db in
            func count(_ q: QueryInterfaceRequest<MailThread>) -> Int {
                (try? q.fetchCount(db)) ?? 0
            }
            let unread = MailThread.filter(Column("isUnread") == true && Column("inTrash") == false)
            var inboxUnread = unread.filter(Column("inInbox") == true)
            for cat in Self.categoryLabels {
                inboxUnread = inboxUnread.filter(!Column("labelIds").like("%\(cat)%"))
            }
            return [
                "inbox": count(inboxUnread),
                "promotions": count(unread.filter(Column("labelIds").like("%CATEGORY_PROMOTIONS%"))),
                "social": count(unread.filter(Column("labelIds").like("%CATEGORY_SOCIAL%"))),
                "reminders": count(MailThread.filter(Column("reminderAt") != nil)),
            ]
        }) ?? [:]
        unreadCounts = counts
        Notifier.setBadge(counts["inbox"] ?? 0)
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
        try? db.write { db in
            var v = view
            try v.save(db)
        }
        reloadSavedViews()
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
                                      historyId: nil, lastSyncAt: nil)
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
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.syncAll()
                self?.fireDueReminders()
            }
        }
    }

    func syncAll() async {
        for account in accounts { await sync(accountId: account.id) }
        notifyNewMail()
        rebuildContacts()
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
            reloadAccounts()
            reloadThreads()
        } catch {
            syncStatus = ""
            lastError = "\(accountId): \(error.localizedDescription)"
        }
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
        copy.reminderAt = days.map { Calendar.current.date(byAdding: .day, value: $0, to: Date())! }
        let updated = copy
        try? db.write { db in try updated.save(db) }
        reloadThreads()
    }

    private func fireDueReminders() {
        let due = (try? db.read { db in
            try MailThread.filter(Column("reminderAt") != nil && Column("reminderAt") <= Date()).fetchAll(db)
        }) ?? []
        for thread in due {
            Notifier.notify(title: "Follow up: \(thread.fromDisplay)",
                            body: thread.subject.isEmpty ? thread.snippet : thread.subject,
                            id: "reminder.\(thread.id)")
            var copy = thread
            copy.reminderAt = nil
            let updated = copy
            try? db.write { db in try updated.save(db) }
        }
        if !due.isEmpty { reloadThreads() }
    }

    // MARK: - Keyboard shortcuts

    /// Returns true if the key was handled.
    func handleKey(_ chars: String) -> Bool {
        switch chars {
        case "e": selectedThread.map(archive)
        case "#": selectedThread.map(trash)
        case "s": selectedThread.map(toggleStar)
        case "u": if let t = selectedThread { setRead(t, read: t.isUnread) }
        case "h": if let t = selectedThread { snooze(t, until: Self.snoozeDate(hour: 8, addDays: 1)) }
        case "j": moveSelection(1)
        case "k": moveSelection(-1)
        case "r": if let t = selectedThread {
                      composeRequest = ComposeRequest(replyTo: messages(inThread: t.id).last)
                  }
        case "c": composeRequest = ComposeRequest(replyTo: nil)
        default: return false
        }
        return true
    }

    func moveSelection(_ delta: Int) {
        guard !threads.isEmpty else { return }
        let idx = threads.firstIndex { $0.id == selectedThreadId } ?? (delta > 0 ? -1 : 0)
        let next = min(max(idx + delta, 0), threads.count - 1)
        selectedThreadId = threads[next].id
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

    func archive(_ thread: MailThread) {
        mutateThread(thread) { $0.inInbox = false } remote: { client, id in
            try await client.modifyThread(id: id, remove: ["INBOX"])
        }
        offerUndo("Archived") { [weak self] in
            guard let self else { return }
            self.mutateThread(thread) { $0.inInbox = true } remote: { client, id in
                try await client.modifyThread(id: id, add: ["INBOX"])
            }
            self.undoAction = nil
        }
    }

    func trash(_ thread: MailThread) {
        mutateThread(thread) { $0.inTrash = true; $0.inInbox = false } remote: { client, id in
            try await client.trashThread(id: id)
        }
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
        mutateThread(thread) { $0.isUnread = !read } remote: { client, id in
            try await client.modifyThread(id: id, add: read ? [] : ["UNREAD"],
                                          remove: read ? ["UNREAD"] : [])
        }
    }

    /// Snooze is local-only: the thread is hidden from the inbox until the
    /// date passes. (Gmail has no first-class snooze API.)
    func snooze(_ thread: MailThread, until date: Date?) {
        var copy = thread
        copy.snoozeUntil = date
        let updated = copy
        try? db.write { db in try updated.save(db) }
        reloadThreads()
    }

    // MARK: - Sending

    func send(from accountId: String, to: String, cc: String, subject: String,
              body: String, replyTo message: Message? = nil,
              attachments: [MIMEBuilder.Attachment] = []) async throws {
        let raw = MIMEBuilder.build(
            from: accountId, to: to, cc: cc, subject: subject, bodyText: body,
            inReplyTo: message?.messageIdHeader,
            references: message?.referencesHeader,
            attachments: attachments
        )
        let gmailThreadId = message.map { String($0.threadId.split(separator: ":").last!) }
        try await client(for: accountId).send(raw: raw, threadId: gmailThreadId)
        await sync(accountId: accountId)
    }

    // MARK: - Attachments

    func openAttachment(_ attachment: AttachmentRow, message: Message) {
        Task {
            do {
                let data = try await client(for: message.accountId)
                    .getAttachment(messageId: message.gmailId, attachmentId: attachment.gmailAttachmentId)
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("PerfectMailAttachments", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent(attachment.filename)
                try data.write(to: url)
                await MainActor.run { NSWorkspace.shared.open(url) }
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
        }
    }

    // MARK: - Snippets

    func snippets() -> [Snippet] {
        (try? db.read { try Snippet.order(Column("name")).fetchAll($0) }) ?? []
    }

    func saveSnippet(name: String, body: String) {
        try? db.write { db in
            var s = Snippet(id: nil, name: name, body: body)
            try s.insert(db)
        }
        objectWillChange.send()
    }

    func deleteSnippet(_ s: Snippet) {
        try? db.write { db in _ = try Snippet.deleteOne(db, key: s.id) }
        objectWillChange.send()
    }
}
