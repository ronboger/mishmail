import Foundation
import GRDB

/// Per-account sync: initial backfill via messages.list, then cheap
/// incremental catch-up via history.list keyed on the stored historyId.
actor SyncEngine {
    private let client: GmailClient
    private let accountId: String
    private let db = AppDatabase.shared.dbQueue

    /// Sentinel for "keep no mail on this Mac" (0 already means "everything").
    static let windowNothing = -1

    /// Configurable per-account sync window (Settings → Accounts).
    /// Falls back to the old global key so existing installs keep their
    /// setting. 0 = everything, `windowNothing` = keep no mail locally.
    static func syncWindowDays(for accountId: String) -> Int {
        let defaults = UserDefaults.standard
        if let v = defaults.object(forKey: "syncWindowDays.\(accountId)") as? Int { return v }
        return defaults.object(forKey: "syncWindowDays") as? Int ?? 90
    }

    private var syncWindowDays: Int { Self.syncWindowDays(for: accountId) }

    private var windowQuery: String? {
        syncWindowDays == 0 ? nil : "newer_than:\(syncWindowDays)d"
    }

    private var windowLimit: Int {
        syncWindowDays == 0 ? 50_000 : max(3000, syncWindowDays * 60)
    }

    init(accountId: String) {
        self.accountId = accountId
        self.client = GmailClient(accountEmail: accountId)
    }

    func syncNow(progress: (@Sendable (String) -> Void)? = nil) async throws {
        let account = try await db.read { [accountId] db in
            try Account.fetchOne(db, key: accountId)
        }
        guard var account else { return }

        try await syncLabels()

        let windowKey = "backfill.window.\(accountId)"

        // "Nothing": remove all locally stored mail for this account and
        // skip message sync entirely. Gmail is never touched.
        if syncWindowDays == Self.windowNothing {
            if UserDefaults.standard.integer(forKey: windowKey) != Self.windowNothing {
                progress?("Removing local mail…")
                try await pruneLocalMail(keepingDays: nil)
                UserDefaults.standard.set(Self.windowNothing, forKey: windowKey)
                UserDefaults.standard.set(false, forKey: "backfill.starred.\(accountId)")
            }
            account.historyId = nil  // full backfill if a window is chosen again
            account.lastSyncAt = Date()
            let updated = account
            try await db.write { db in try updated.update(db) }
            return
        }

        if let historyId = account.historyId {
            do {
                account.historyId = try await incrementalSync(since: historyId, progress: progress)
            } catch GmailError.historyExpired {
                account.historyId = try await fullBackfill(progress: progress)
            }
        } else {
            account.historyId = try await fullBackfill(progress: progress)
        }

        // When the configured window changed: backfill anything newly inside
        // it, and remove local copies of mail that fell outside it (starred
        // mail is kept; Gmail is never touched). Always pull ALL starred mail
        // regardless of age (once).
        if UserDefaults.standard.integer(forKey: windowKey) != syncWindowDays {
            try await fetchAll(query: windowQuery, limit: windowLimit, progress: progress)
            if syncWindowDays != 0 {
                progress?("Removing local mail outside the window…")
                try await pruneLocalMail(keepingDays: syncWindowDays)
            }
            UserDefaults.standard.set(syncWindowDays, forKey: windowKey)
        }
        let starKey = "backfill.starred.\(accountId)"
        if !UserDefaults.standard.bool(forKey: starKey) {
            try await fetchAll(query: "is:starred", limit: 3000, progress: progress)
            UserDefaults.standard.set(true, forKey: starKey)
        }

        account.lastSyncAt = Date()
        let updated = account
        try await db.write { db in try updated.update(db) }
    }

    /// Recomputes every thread row for this account from its messages.
    /// Used after schema upgrades that add derived thread columns.
    func rebuildAllThreadMetadata() async throws {
        try await rebuildThreads()
    }

    // MARK: - Labels

    private func syncLabels() async throws {
        let labels = try await client.labels()
        try await db.write { [accountId] db in
            for l in labels {
                let id = "\(accountId):\(l.id)"
                // Color and order are local customizations — a resync must
                // never wipe them. Gmail's own label color only seeds a label
                // that has no local color yet.
                let existing = try LabelRow.fetchOne(db, key: id)
                try LabelRow(id: id, accountId: accountId,
                             gmailLabelId: l.id, name: l.name, type: l.type ?? "user",
                             color: existing?.color ?? l.color?.backgroundColor,
                             sortOrder: existing?.sortOrder ?? LabelRow.unsorted).save(db)
            }
        }
    }

    // MARK: - Backfill

    private func fullBackfill(progress: (@Sendable (String) -> Void)?) async throws -> String {
        let profile = try await client.profile()
        try await fetchAll(query: windowQuery, limit: windowLimit, progress: progress)
        UserDefaults.standard.set(syncWindowDays, forKey: "backfill.window.\(accountId)")
        return profile.historyId
    }

    // MARK: - Local removal

    /// Deletes locally stored mail for this account without touching Gmail.
    /// `keepingDays` keeps mail newer than that many days (starred mail is
    /// always kept); nil removes everything. Attachments cascade; thread rows
    /// are rebuilt from what remains.
    func pruneLocalMail(keepingDays: Int?) async throws {
        let cutoff = keepingDays.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        try await db.write { [accountId] db in
            try Self.pruneMessages(db, accountId: accountId, olderThan: cutoff)
        }
        try await rebuildThreads()
    }

    /// Deletes this account's messages older than `cutoff` (starred kept),
    /// or all of them when cutoff is nil. Pure SQL — exercised directly by
    /// the test suite.
    static func pruneMessages(_ db: Database, accountId: String, olderThan cutoff: Date?) throws {
        if let cutoff {
            try db.execute(sql: """
                DELETE FROM message WHERE accountId = ? AND date < ?
                AND labelIds NOT LIKE '%STARRED%'
                """, arguments: [accountId, cutoff])
        } else {
            try db.execute(sql: "DELETE FROM message WHERE accountId = ?",
                           arguments: [accountId])
        }
    }

    /// Lists messages matching a query and downloads only the ones missing
    /// from the local cache.
    /// Server-side search: downloads messages matching a Gmail query that
    /// aren't already cached (so a search can reach mail outside the local sync
    /// window), then rebuilds the affected threads. Gmail's `q` syntax matches
    /// the app's search operators (from:/to:/subject:/is:/before:/after:…).
    func searchServer(query: String, limit: Int = 50) async throws {
        try await fetchAll(query: query, limit: limit, progress: nil)
        try await rebuildThreads()
    }

    private func fetchAll(query: String?, limit: Int,
                          progress: (@Sendable (String) -> Void)?) async throws {
        let existing = try await db.read { [accountId] db in
            Set(try String.fetchAll(db, sql: "SELECT gmailId FROM message WHERE accountId = ?",
                                    arguments: [accountId]))
        }
        var pageToken: String?
        var listed = 0
        var fetched = 0
        repeat {
            let page = try await client.listMessages(query: query, pageToken: pageToken, maxResults: 100)
            let refs = (page.messages ?? []).filter { !existing.contains($0.id) }
            listed += page.messages?.count ?? 0
            try await withThrowingTaskGroup(of: GMessage.self) { group in
                var pending = 0
                var iterator = refs.makeIterator()
                func addNext() {
                    if let ref = iterator.next() {
                        group.addTask { [client] in try await client.getMessage(id: ref.id) }
                        pending += 1
                    }
                }
                for _ in 0..<8 { addNext() }  // bounded concurrency
                while pending > 0 {
                    let msg = try await group.next()!
                    pending -= 1
                    try await self.upsert(msg)
                    addNext()
                }
            }
            fetched += refs.count
            if fetched > 0 { progress?("Downloaded \(fetched) messages…") }
            pageToken = page.nextPageToken
        } while pageToken != nil && listed < limit
    }

    // MARK: - Incremental

    private func incrementalSync(since historyId: String, progress: (@Sendable (String) -> Void)?) async throws -> String {
        var pageToken: String?
        var latest = historyId
        var touched = Set<String>()   // gmail message ids to refetch
        var deleted = Set<String>()
        repeat {
            let page = try await client.history(since: historyId, pageToken: pageToken)
            for item in page.history ?? [] {
                for m in item.messagesAdded ?? [] { touched.insert(m.message.id) }
                for m in item.labelsAdded ?? [] { touched.insert(m.message.id) }
                for m in item.labelsRemoved ?? [] { touched.insert(m.message.id) }
                for m in item.messagesDeleted ?? [] { deleted.insert(m.message.id) }
            }
            if let h = page.historyId { latest = h }
            pageToken = page.nextPageToken
        } while pageToken != nil

        touched.subtract(deleted)
        for id in deleted {
            let key = "\(accountId):\(id)"
            _ = try await db.write { db in try Message.deleteOne(db, key: key) }
        }
        for id in touched {
            if let msg = try? await client.getMessage(id: id) {
                try await upsert(msg)
            }
        }
        // Recompute thread rows for anything affected.
        if !touched.isEmpty || !deleted.isEmpty {
            try await rebuildThreads()
            progress?("Updated \(touched.count) messages")
        }
        return latest
    }

    // MARK: - Local writes

    private func upsert(_ g: GMessage) async throws {
        let (message, attachments) = MessageParser.parse(g, accountId: accountId)
        try await db.write { db in
            try message.save(db)
            try AttachmentRow.filter(Column("messageId") == message.id).deleteAll(db)
            for var att in attachments { try att.insert(db) }
        }
        try await upsertThread(threadKey: message.threadId, gmailThreadId: g.threadId)
    }

    private func upsertThread(threadKey: String, gmailThreadId: String) async throws {
        try await db.write { [accountId] db in
            let messages = try Message
                .filter(Column("threadId") == threadKey)
                .order(Column("date").desc)
                .fetchAll(db)
            let existing = try MailThread.fetchOne(db, key: threadKey)
            guard let thread = Self.deriveThread(
                threadKey: threadKey, gmailThreadId: gmailThreadId,
                accountId: accountId, messages: messages, existing: existing) else { return }
            try thread.save(db)
        }
    }

    /// Derives a thread row from its messages (sorted newest first).
    /// Pure — exercised directly by the test suite.
    static func deriveThread(threadKey: String, gmailThreadId: String, accountId: String,
                             messages: [Message], existing: MailThread?) -> MailThread? {
        guard let newest = messages.first else { return nil }
        let allLabels = Set(messages.flatMap { $0.labelIds.split(separator: " ").map(String.init) })

        // Participants in chronological order, deduped, own account as "me".
        var seen = Set<String>()
        var participants: [String] = []
        for m in messages.reversed() {
            let sender = MessageParser.emailAddress(m.fromHeader)
            let name = sender == accountId ? "me" : MessageParser.displayName(fromHeader: m.fromHeader)
            let short = name.split(separator: " ").first.map(String.init) ?? name
            if seen.insert(short).inserted { participants.append(short) }
        }

        return MailThread(
            id: threadKey,
            accountId: accountId,
            gmailThreadId: gmailThreadId,
            subject: messages.last?.subject.isEmpty == false ? messages.last!.subject : newest.subject,
            snippet: newest.snippet,
            fromDisplay: MessageParser.displayName(fromHeader: newest.fromHeader),
            lastDate: newest.date,
            isUnread: messages.contains { $0.isUnread },
            isStarred: allLabels.contains("STARRED"),
            inInbox: allLabels.contains("INBOX"),
            inTrash: allLabels.contains("TRASH"),
            labelIds: allLabels.sorted().joined(separator: " "),
            snoozeUntil: existing?.snoozeUntil,
            participants: participants.joined(separator: " .. "),
            messageCount: messages.count,
            hasAttachment: messages.contains { $0.hasAttachment },
            reminderAt: existing?.reminderAt,
            reminderSetAt: existing?.reminderSetAt
        )
    }

    private func rebuildThreads() async throws {
        let pairs = try await db.read { [accountId] db -> [(String, String)] in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT threadId FROM message WHERE accountId = ?
                """, arguments: [accountId])
            return rows.map { row in
                let key: String = row["threadId"]
                let gmailId = String(key.split(separator: ":").last ?? "")
                return (key, gmailId)
            }
        }
        // Remove threads whose messages are all gone.
        try await db.write { [accountId] db in
            try db.execute(sql: """
                DELETE FROM thread WHERE accountId = ?
                AND id NOT IN (SELECT DISTINCT threadId FROM message WHERE accountId = ?)
                """, arguments: [accountId, accountId])
        }
        for (key, gmailId) in pairs {
            try await upsertThread(threadKey: key, gmailThreadId: gmailId)
        }
    }
}
