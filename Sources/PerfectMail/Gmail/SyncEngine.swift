import Foundation
import GRDB

/// Per-account sync: initial backfill via messages.list, then cheap
/// incremental catch-up via history.list keyed on the stored historyId.
actor SyncEngine {
    private let client: GmailClient
    private let accountId: String
    private let db = AppDatabase.shared.dbQueue

    /// Configurable sync window (Settings → Accounts). 0 = everything.
    static var syncWindowDays: Int {
        UserDefaults.standard.object(forKey: "syncWindowDays") as? Int ?? 90
    }

    private static var windowQuery: String? {
        syncWindowDays == 0 ? nil : "newer_than:\(syncWindowDays)d"
    }

    private static var windowLimit: Int {
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

        if let historyId = account.historyId {
            do {
                account.historyId = try await incrementalSync(since: historyId, progress: progress)
            } catch GmailError.historyExpired {
                account.historyId = try await fullBackfill(progress: progress)
            }
        } else {
            account.historyId = try await fullBackfill(progress: progress)
        }

        // Deepen the archive when the configured window grew, and always
        // pull ALL starred mail regardless of age (once).
        let windowKey = "backfill.window.\(accountId)"
        if UserDefaults.standard.integer(forKey: windowKey) != Self.syncWindowDays {
            try await fetchAll(query: Self.windowQuery, limit: Self.windowLimit, progress: progress)
            UserDefaults.standard.set(Self.syncWindowDays, forKey: windowKey)
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
                try LabelRow(id: "\(accountId):\(l.id)", accountId: accountId,
                             gmailLabelId: l.id, name: l.name, type: l.type ?? "user").save(db)
            }
        }
    }

    // MARK: - Backfill

    private func fullBackfill(progress: (@Sendable (String) -> Void)?) async throws -> String {
        let profile = try await client.profile()
        try await fetchAll(query: Self.windowQuery, limit: Self.windowLimit, progress: progress)
        UserDefaults.standard.set(Self.syncWindowDays, forKey: "backfill.window.\(accountId)")
        return profile.historyId
    }

    /// Lists messages matching a query and downloads only the ones missing
    /// from the local cache.
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
            reminderAt: existing?.reminderAt
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
