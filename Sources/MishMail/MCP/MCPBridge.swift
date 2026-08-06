import Foundation
import GRDB

/// Real `MCPToolProvider` backed by GRDB reads and MainActor `MailStore` mutations.
///
/// Reads go straight to `AppDatabase.shared` (pool is thread-safe). Draft and
/// VIP mutations hop to `@MainActor` so optimistic UI + Gmail side effects stay
/// on the same path as the rest of the app.
final class MCPBridge: MCPToolProvider, @unchecked Sendable {
    /// Weak so the server does not extend the store past quit.
    private weak var store: MailStore?

    init(store: MailStore) {
        self.store = store
    }

    // MARK: - list_accounts

    func listAccounts() async throws -> String {
        let rows = try await AppDatabase.shared.dbPool.read { db in
            try Account.fetchAll(db)
        }
        let payload = rows.map {
            ["id": $0.id, "email": $0.id, "displayName": $0.displayName]
        }
        return try encodeJSON(payload)
    }

    // MARK: - list_threads

    func listThreads(
        mailbox: String,
        unreadOnly: Bool?,
        limit: Int,
        offset: Int,
        account: String?
    ) async throws -> String {
        let mb = mailbox.lowercased()
        let allowed = ["primary", "correspondence", "inbox", "starred",
                       "sent", "drafts", "all"]
        guard allowed.contains(mb) else {
            throw MCPToolError("mailbox must be one of: \(allowed.joined(separator: ", "))")
        }

        let threads: [MailThread] = try await AppDatabase.shared.dbPool.read { db in
            var sql = "SELECT * FROM thread WHERE inTrash = 0 AND inSpam = 0"
            var args: [any DatabaseValueConvertible] = []
            switch mb {
            case "primary":
                // Real correspondence, not bulk mail: excludes all four Gmail
                // categories. Promotions/Social have denormalized columns;
                // Updates/Forums live only in the space-separated labelIds,
                // so pad both sides to match a whole label.
                sql += """
                     AND inInbox = 1 AND inPromotions = 0 AND inSocial = 0
                     AND (' ' || labelIds || ' ') NOT LIKE '% CATEGORY_UPDATES %'
                     AND (' ' || labelIds || ' ') NOT LIKE '% CATEGORY_FORUMS %'
                    """
            case "correspondence":
                // Threads you actually took part in: an inbox thread that also
                // has a SENT message. Catches real conversations Gmail files
                // under Updates (insurance claims, vendor threads) which the
                // category filter would otherwise drop.
                sql += " AND inInbox = 1 AND inSent = 1"
            case "inbox":
                sql += " AND inInbox = 1"
            case "starred":
                sql += " AND isStarred = 1"
            case "sent":
                sql += " AND inSent = 1"
            case "drafts":
                sql += " AND inDrafts = 1"
            default:
                break // all
            }
            if unreadOnly == true {
                sql += " AND isUnread = 1"
            }
            if let account, !account.isEmpty {
                sql += " AND accountId = ?"
                args.append(account)
            }
            sql += " ORDER BY lastDate DESC LIMIT ? OFFSET ?"
            args.append(limit)
            args.append(offset)
            return try MailThread.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }

        let summaries = try await loadSummaries(for: threads.map(\.id))
        let categories = try await loadCategories(for: threads.map(\.id))
        let payload = threads.map { thread -> [String: Any] in
            var row: [String: Any] = [
                "id": thread.id,
                "accountId": thread.accountId,
                "subject": thread.subject,
                "snippet": thread.snippet,
                "from": thread.fromDisplay,
                "date": ISO8601DateFormatter().string(from: thread.lastDate),
                "isUnread": thread.isUnread,
                "isStarred": thread.isStarred,
                "inInbox": thread.inInbox,
                "inSent": thread.inSent,
                "inDrafts": thread.inDrafts,
                "inPromotions": thread.inPromotions,
                "inSocial": thread.inSocial,
            ]
            if let category = categories[thread.id] {
                row["category"] = category
            }
            if let summary = summaries[thread.id] {
                row["summary"] = summary.summary
                row["summaryModel"] = summary.model
                row["summaryUpdatedAt"] = ISO8601DateFormatter().string(from: summary.updatedAt)
                // New mail arrived after the summary was written, so it no
                // longer describes the whole thread.
                row["summaryStale"] = thread.lastDate > summary.updatedAt
            }
            return row
        }
        return try encodeJSON(payload)
    }

    // MARK: - search_threads

    func searchThreads(query: String, limit: Int, offset: Int) async throws -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            throw MCPToolError("query must not be empty")
        }

        var threads = try await localSearchThreads(query: q, limit: limit, offset: offset)

        // Local index only covers the sync window. Same as the UI's
        // "Search all of Gmail" button: pull matching older mail from the
        // server when the first page is empty, then surface those hits.
        if MCPTools.shouldPullServerSearch(localCount: threads.count, offset: offset),
           let store {
            let serverIds = await store.pullServerSearchMatches(query: q, limit: limit)
            if !serverIds.isEmpty {
                threads = try await threadsByIds(serverIds, limit: limit)
            }
            // If Gmail listed nothing (or download failed), keep the empty local
            // result — agents see [] rather than a confusing error for "no mail".
        }

        let summaries = try await loadSummaries(for: threads.map(\.id))
        let payload = threads.map { thread -> [String: Any] in
            var row: [String: Any] = [
                "id": thread.id,
                "accountId": thread.accountId,
                "subject": thread.subject,
                "snippet": thread.snippet,
                "from": thread.fromDisplay,
                "date": ISO8601DateFormatter().string(from: thread.lastDate),
                "isUnread": thread.isUnread,
                "isStarred": thread.isStarred,
            ]
            if let summary = summaries[thread.id] {
                row["summary"] = summary.summary
                row["summaryModel"] = summary.model
            }
            return row
        }
        return try encodeJSON(payload)
    }

    /// Local FTS5 (subject/from/…) with LIKE fallback. Does not hit the network.
    private func localSearchThreads(query: String, limit: Int, offset: Int) async throws -> [MailThread] {
        try await AppDatabase.shared.dbPool.read { db in
            if let pattern = FTS5Pattern(matchingAllPrefixesIn: query) {
                do {
                    return try MailThread.fetchAll(db, sql: """
                        SELECT DISTINCT thread.*
                        FROM message_fts
                        JOIN message ON message.rowid = message_fts.rowid
                        JOIN thread ON thread.id = message.threadId
                        WHERE message_fts MATCH ?
                          AND thread.inTrash = 0
                        ORDER BY thread.lastDate DESC
                        LIMIT ? OFFSET ?
                        """, arguments: [pattern, limit, offset])
                } catch {
                    // FTS query syntax error → LIKE fallback below.
                }
            }
            let like = "%\(query)%"
            return try MailThread.fetchAll(db, sql: """
                SELECT * FROM thread
                WHERE inTrash = 0
                  AND (subject LIKE ? OR fromDisplay LIKE ?)
                ORDER BY lastDate DESC
                LIMIT ? OFFSET ?
                """, arguments: [like, like, limit, offset])
        }
    }

    /// Load threads by id, preserving caller order (Gmail rank). Skips ids
    /// that never landed in the DB (partial download / deleted).
    private func threadsByIds(_ ids: [String], limit: Int) async throws -> [MailThread] {
        guard !ids.isEmpty else { return [] }
        let capped = Array(ids.prefix(limit))
        let found: [MailThread] = try await AppDatabase.shared.dbPool.read { db in
            try MailThread.filter(capped.contains(Column("id"))).fetchAll(db)
        }
        let byId = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
        return capped.compactMap { byId[$0] }
    }

    // MARK: - get_thread

    func getThread(threadId: String) async throws -> String {
        let (thread, messages, attachments): (MailThread, [Message], [AttachmentRow]) =
            try await AppDatabase.shared.dbPool.read { db in
                guard let thread = try MailThread.fetchOne(db, key: threadId) else {
                    throw MCPToolError("Thread not found: \(threadId)")
                }
                var msgs = try Message
                    .filter(Column("threadId") == threadId)
                    .order(Column("date"))
                    .fetchAll(db)
                let ids = msgs.map(\.id)
                if !ids.isEmpty {
                    let bodies = try MessageBody
                        .filter(ids.contains(Column("messageId")))
                        .fetchAll(db)
                    let byId = Dictionary(uniqueKeysWithValues: bodies.map { ($0.messageId, $0) })
                    for i in msgs.indices {
                        if let body = byId[msgs[i].id] {
                            msgs[i].bodyText = body.bodyText
                            msgs[i].bodyHTML = body.bodyHTML
                        }
                    }
                }
                let atts: [AttachmentRow]
                if ids.isEmpty {
                    atts = []
                } else {
                    atts = try AttachmentRow
                        .filter(ids.contains(Column("messageId")))
                        .fetchAll(db)
                }
                return (thread, msgs, atts)
            }

        let refs = attachments.map {
            ThreadExporter.AttachmentRef(messageId: $0.messageId, filename: $0.filename)
        }
        return ThreadExporter.markdown(
            subject: thread.subject, messages: messages, attachments: refs)
    }

    // MARK: - list_drafts

    func listDrafts(account: String?) async throws -> String {
        let messages: [Message] = try await AppDatabase.shared.dbPool.read { db in
            var sql = """
                SELECT * FROM message
                WHERE (' ' || labelIds || ' ') LIKE '% DRAFT %'
                """
            var args: [any DatabaseValueConvertible] = []
            if let account, !account.isEmpty {
                sql += " AND accountId = ?"
                args.append(account)
            }
            sql += " ORDER BY date DESC LIMIT 100"
            return try Message.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
        let payload = messages.map { msg -> [String: Any] in
            [
                "id": msg.id,
                "threadId": msg.threadId,
                "accountId": msg.accountId,
                "subject": msg.subject,
                "to": msg.toHeader,
                "snippet": msg.snippet,
                "date": ISO8601DateFormatter().string(from: msg.date),
            ]
        }
        return try encodeJSON(payload)
    }

    // MARK: - create_draft

    func createDraft(
        account: String,
        to: [String],
        cc: [String]?,
        bcc: [String]?,
        subject: String,
        body: String,
        replyToThreadId: String?
    ) async throws -> String {
        let accountId = account.trimmingCharacters(in: .whitespaces)
        guard !accountId.isEmpty else {
            throw MCPToolError("account is required")
        }
        let recipients = to.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !recipients.isEmpty else {
            throw MCPToolError("at least one recipient is required")
        }

        // Validate account exists (and optionally resolve reply parent) off MainActor.
        let replyParent: Message? = try await AppDatabase.shared.dbPool.read { db in
            guard try Account.fetchOne(db, key: accountId) != nil else {
                throw MCPToolError("Unknown account: \(accountId)")
            }
            guard let threadId = replyToThreadId, !threadId.isEmpty else { return nil }
            guard try MailThread.fetchOne(db, key: threadId) != nil else {
                throw MCPToolError("reply_to_thread_id not found: \(threadId)")
            }
            // Prefer the newest non-draft message as the reply parent.
            let msgs = try Message
                .filter(Column("threadId") == threadId)
                .order(Column("date").desc)
                .fetchAll(db)
            return msgs.first { msg in
                let labels = Set(msg.labelIds.split(separator: " ").map(String.init))
                return !labels.contains("DRAFT")
            } ?? msgs.first
        }

        let toHeader = recipients.joined(separator: ", ")
        let ccHeader = (cc ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: ", ")
        let bccHeader = (bcc ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: ", ")

        guard let store else {
            throw MCPToolError("Mail store is unavailable")
        }

        // saveDraft is MainActor-isolated on MailStore.
        let draft = await store.saveDraft(
            from: accountId,
            to: toHeader,
            cc: ccHeader,
            bcc: bccHeader,
            subject: subject,
            body: body,
            replyTo: replyParent,
            silent: true,
            syncAfter: true
        )

        guard let draft else {
            throw MCPToolError("Failed to create draft (demo mode or API error)")
        }
        let payload: [String: Any] = [
            "id": draft.id,
            "threadId": draft.threadId,
            "accountId": draft.accountId,
            "subject": draft.subject,
        ]
        return try encodeJSON(payload)
    }

    // MARK: - set_thread_summary

    func setThreadSummary(threadId: String, summary: String, model: String) async throws -> String {
        let tid = threadId.trimmingCharacters(in: .whitespaces)
        guard !tid.isEmpty else { throw MCPToolError("thread_id is required") }
        let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MCPToolError("summary must not be empty") }
        let modelName = model.trimmingCharacters(in: .whitespaces)
        guard !modelName.isEmpty else { throw MCPToolError("model is required") }

        let exists = try await AppDatabase.shared.dbPool.read { db in
            try MailThread.fetchOne(db, key: tid) != nil
        }
        guard exists else {
            throw MCPToolError("Thread not found: \(tid)")
        }
        try await AppDatabase.shared.dbPool.write { db in
            let row = ThreadSummaryRow(
                threadId: tid,
                summary: text,
                model: modelName,
                updatedAt: Date()
            )
            try row.save(db)
        }
        return try encodeJSON([
            "threadId": tid,
            "summary": text,
            "model": modelName,
        ] as [String: Any])
    }

    func clearThreadSummary(threadId: String) async throws -> String {
        let tid = threadId.trimmingCharacters(in: .whitespaces)
        guard !tid.isEmpty else { throw MCPToolError("thread_id is required") }
        let deleted = try await AppDatabase.shared.dbPool.write { db in
            try ThreadSummaryRow.deleteOne(db, key: tid)
        }
        return try encodeJSON(["threadId": tid, "cleared": deleted] as [String: Any])
    }

    // MARK: - VIP tools

    func listVIPs() async throws -> String {
        let (senders, groups): ([VIPSender], [VIPGroupRow]) =
            try await AppDatabase.shared.dbPool.read { db in
                (try VIPSender.fetchAll(db), try VIPGroupRow.fetchAll(db))
            }
        let enabledByName = Dictionary(uniqueKeysWithValues: groups.map { ($0.name, $0.enabled) })
        let payload = senders.map { s -> [String: Any] in
            var row: [String: Any] = ["email": s.email]
            if let g = s.groupName {
                row["group"] = g
                row["groupEnabled"] = enabledByName[g] ?? true
            }
            return row
        }
        return try encodeJSON(payload)
    }

    func addVIP(email: String, group: String?) async throws -> String {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard e.contains("@") else {
            throw MCPToolError("Invalid email: \(email)")
        }
        let groupName = (group?.trimmingCharacters(in: .whitespaces)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "Suggested"

        guard let store else {
            throw MCPToolError("Mail store is unavailable")
        }
        // addVIP silently no-ops in the demo inbox; agents need the refusal.
        if await MainActor.run(body: { store.demoMode }) {
            throw MCPToolError("VIP changes are disabled in the demo inbox")
        }
        await MainActor.run {
            store.addVIP(e, group: groupName)
        }
        return try encodeJSON(["email": e, "group": groupName] as [String: Any])
    }

    func removeVIP(email: String) async throws -> String {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard e.contains("@") else {
            throw MCPToolError("Invalid email: \(email)")
        }
        guard let store else {
            throw MCPToolError("Mail store is unavailable")
        }
        if await MainActor.run(body: { store.demoMode }) {
            throw MCPToolError("VIP changes are disabled in the demo inbox")
        }
        await MainActor.run {
            store.removeVIP(e)
        }
        return try encodeJSON(["email": e, "removed": true] as [String: Any])
    }

    // MARK: - Helpers

    /// On-device triage categories (Reply needed / FYI / Newsletter / Receipt
    /// / Other). Only populated for threads the app has classified — enable
    /// Auto-sort in Settings → AI to fill this in.
    private func loadCategories(for threadIds: [String]) async throws -> [String: String] {
        guard !threadIds.isEmpty else { return [:] }
        let rows = try await AppDatabase.shared.dbPool.read { db in
            try ThreadAICategory.filter(threadIds.contains(Column("threadId"))).fetchAll(db)
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.threadId, $0.category) })
    }

    private func loadSummaries(for threadIds: [String]) async throws -> [String: ThreadSummaryRow] {
        guard !threadIds.isEmpty else { return [:] }
        let rows = try await AppDatabase.shared.dbPool.read { db in
            try ThreadSummaryRow.filter(threadIds.contains(Column("threadId"))).fetchAll(db)
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.threadId, $0) })
    }

    private func encodeJSON(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard let s = String(data: data, encoding: .utf8) else {
            throw MCPToolError("Failed to encode JSON")
        }
        return s
    }
}
