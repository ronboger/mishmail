import Foundation
import SwiftUI
import GRDB

enum MailboxView: Hashable {
    case inbox          // unified inbox across accounts
    case starred
    case snoozed
    case sent
    case trash
    case account(String)          // one account's inbox
    case label(account: String, labelId: String, name: String)

    var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .starred: return "Starred"
        case .snoozed: return "Snoozed"
        case .sent: return "Sent"
        case .trash: return "Trash"
        case .account(let a): return a
        case .label(_, _, let name): return name
        }
    }
}

@MainActor
final class MailStore: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var labelsByAccount: [String: [LabelRow]] = [:]
    @Published var threads: [MailThread] = []
    @Published var selectedView: MailboxView = .inbox
    @Published var selectedThreadId: String?
    @Published var searchText: String = ""
    @Published var syncStatus: String = ""
    @Published var lastError: String?
    @Published var composeRequest: ComposeRequest?

    struct ComposeRequest: Identifiable {
        let id = UUID()
        let replyTo: Message?
    }

    var selectedThread: MailThread? {
        threads.first { $0.id == selectedThreadId }
    }

    private let db = AppDatabase.shared.dbQueue
    private var syncTimer: Timer?
    private var engines: [String: SyncEngine] = [:]
    private var clients: [String: GmailClient] = [:]

    init() {
        reloadAccounts()
        reloadThreads()
        startPolling()
    }

    func client(for accountId: String) -> GmailClient {
        if let c = clients[accountId] { return c }
        let c = GmailClient(accountEmail: accountId)
        clients[accountId] = c
        return c
    }

    // MARK: - Loading

    func reloadAccounts() {
        accounts = (try? db.read { try Account.order(Column("id")).fetchAll($0) }) ?? []
        labelsByAccount = Dictionary(grouping: (try? db.read {
            try LabelRow.filter(Column("type") == "user").order(Column("name")).fetchAll($0)
        }) ?? [], by: \.accountId)
    }

    func reloadThreads() {
        let view = selectedView
        let search = searchText.trimmingCharacters(in: .whitespaces)
        threads = (try? db.read { db -> [MailThread] in
            if !search.isEmpty {
                let ids = try Row.fetchAll(db, sql: """
                    SELECT DISTINCT message.threadId FROM message
                    JOIN message_fts ON message_fts.rowid = message.rowid
                    WHERE message_fts MATCH ?
                    """, arguments: [FTS5Pattern(matchingAllPrefixesIn: search)])
                    .map { $0["threadId"] as String }
                return try MailThread.filter(ids.contains(Column("id")))
                    .order(Column("lastDate").desc).limit(200).fetchAll(db)
            }
            var q = MailThread.order(Column("lastDate").desc).limit(300)
            let now = Date()
            switch view {
            case .inbox:
                q = q.filter(Column("inInbox") == true && Column("inTrash") == false)
                    .filter(Column("snoozeUntil") == nil || Column("snoozeUntil") <= now)
            case .starred:
                q = q.filter(Column("isStarred") == true && Column("inTrash") == false)
            case .snoozed:
                q = q.filter(Column("snoozeUntil") != nil && Column("snoozeUntil") > now)
            case .sent:
                q = q.filter(Column("labelIds").like("%SENT%") && Column("inTrash") == false)
            case .trash:
                q = q.filter(Column("inTrash") == true)
            case .account(let a):
                q = q.filter(Column("accountId") == a && Column("inInbox") == true && Column("inTrash") == false)
            case .label(let a, let labelId, _):
                q = q.filter(Column("accountId") == a)
                    .filter(Column("labelIds").like("%\(labelId)%"))
            }
            return try q.fetchAll(db)
        }) ?? []
    }

    func messages(inThread threadId: String) -> [Message] {
        (try? db.read {
            try Message.filter(Column("threadId") == threadId).order(Column("date")).fetchAll($0)
        }) ?? []
    }

    // MARK: - Account lifecycle

    func addAccount() {
        Task {
            do {
                let (refresh, access) = try await OAuthService().signIn()
                // Resolve which account we just signed into.
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
            Task { @MainActor in await self?.syncAll() }
        }
    }

    func syncAll() async {
        for account in accounts { await sync(accountId: account.id) }
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

    func archive(_ thread: MailThread) {
        mutateThread(thread) { $0.inInbox = false } remote: { client, id in
            try await client.modifyThread(id: id, remove: ["INBOX"])
        }
    }

    func trash(_ thread: MailThread) {
        mutateThread(thread) { $0.inTrash = true; $0.inInbox = false } remote: { client, id in
            try await client.trashThread(id: id)
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

    // MARK: - Keyboard shortcuts (dispatched from an NSEvent monitor so
    // bare letters work reliably, unlike SwiftUI bare-key shortcuts)

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

    // MARK: - Sending

    func send(from accountId: String, to: String, cc: String, subject: String,
              body: String, replyTo message: Message? = nil) async throws {
        let raw = MIMEBuilder.build(
            from: accountId, to: to, cc: cc, subject: subject, bodyText: body,
            inReplyTo: message?.messageIdHeader,
            references: message?.referencesHeader
        )
        let gmailThreadId = message.map { String($0.threadId.split(separator: ":").last!) }
        try await client(for: accountId).send(raw: raw, threadId: gmailThreadId)
        await sync(accountId: accountId)
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
