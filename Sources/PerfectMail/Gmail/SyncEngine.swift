import Foundation
import GRDB

/// Per-account sync: initial backfill via messages.list, then cheap
/// incremental catch-up via history.list keyed on the stored historyId.
actor SyncEngine {
    private let client: GmailClient
    private let accountId: String
    private let db = AppDatabase.shared.dbQueue

    /// How much mail the initial backfill pulls in. Recent-first; older mail
    /// can be backfilled later without any schema change.
    static let initialBackfillQuery = "newer_than:90d"
    static let initialMaxMessages = 1500

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
        account.lastSyncAt = Date()
        let updated = account
        try await db.write { db in try updated.update(db) }
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
        var pageToken: String?
        var fetched = 0
        repeat {
            let page = try await client.listMessages(query: Self.initialBackfillQuery,
                                                     pageToken: pageToken, maxResults: 100)
            let refs = page.messages ?? []
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
            progress?("Synced \(fetched) messages…")
            pageToken = page.nextPageToken
        } while pageToken != nil && fetched < Self.initialMaxMessages
        return profile.historyId
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
        let message = MessageParser.parse(g, accountId: accountId)
        try await db.write { db in try message.save(db) }
        try await upsertThread(threadKey: message.threadId, gmailThreadId: g.threadId)
    }

    private func upsertThread(threadKey: String, gmailThreadId: String) async throws {
        try await db.write { [accountId] db in
            let messages = try Message
                .filter(Column("threadId") == threadKey)
                .order(Column("date").desc)
                .fetchAll(db)
            guard let newest = messages.first else { return }
            let allLabels = Set(messages.flatMap { $0.labelIds.split(separator: " ").map(String.init) })
            let existing = try MailThread.fetchOne(db, key: threadKey)
            let thread = MailThread(
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
                snoozeUntil: existing?.snoozeUntil
            )
            try thread.save(db)
        }
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
