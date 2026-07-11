import Foundation
import GRDB

/// Per-account sync: initial backfill via messages.list, then cheap
/// incremental catch-up via history.list keyed on the stored historyId.
actor SyncEngine {
    private let client: GmailClient
    private let accountId: String
    private let db = AppDatabase.shared.dbPool

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
            let touchedKeys = try await fetchAll(query: windowQuery, limit: windowLimit, progress: progress)
            try await deriveThreads(for: touchedKeys)
            if syncWindowDays != 0 {
                progress?("Removing local mail outside the window…")
                try await pruneLocalMail(keepingDays: syncWindowDays)
            }
            UserDefaults.standard.set(syncWindowDays, forKey: windowKey)
        }
        let starKey = "backfill.starred.\(accountId)"
        if !UserDefaults.standard.bool(forKey: starKey) {
            let touchedKeys = try await fetchAll(query: "is:starred", limit: 3000, progress: progress)
            try await deriveThreads(for: touchedKeys)
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
        let touchedKeys = try await fetchAll(query: windowQuery, limit: windowLimit, progress: progress)
        try await deriveThreads(for: touchedKeys)
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
        let touchedKeys = try await fetchAll(query: query, limit: limit, progress: nil)
        try await deriveThreads(for: touchedKeys)
    }

    /// Downloads messages matching `query` that aren't already cached.
    /// Returns the set of thread keys touched, so callers can batch
    /// re-derivation instead of recomputing every thread in the account.
    ///
    /// Network: bounded concurrent `getMessage` (8). Writes: buffered and
    /// committed in chunks of `writeChunkSize` (one SQLCipher transaction per
    /// chunk). A failure mid-chunk rolls back that chunk only; earlier chunks
    /// stay committed. Progress reports download totals periodically per page.
    ///
    /// Existence: per list page, PK lookup for that page's ids only — never
    /// loads all account gmailIds into a Set (memory stays O(page), not O(mailbox)).
    @discardableResult
    private func fetchAll(query: String?, limit: Int,
                          progress: (@Sendable (String) -> Void)?) async throws -> Set<String> {
        try await PerfMetrics.measureAsync(.syncFetchAll, meta: "limit=\(limit)") {
            var touchedKeys = Set<String>()
            var writeBuffer: [PendingUpsert] = []
            writeBuffer.reserveCapacity(Self.writeChunkSize)
            var pageToken: String?
            var listed = 0
            var fetched = 0
            repeat {
                let page = try await client.listMessages(query: query, pageToken: pageToken, maxResults: 100)
                let listedIds = (page.messages ?? []).map(\.id)
                listed += listedIds.count
                // Per-page missing check (PK IN …) — avoids O(mailbox) Set at start.
                let missingIds = try await db.read { [accountId] db in
                    try Self.filterMissingGmailIds(db, accountId: accountId, listed: listedIds)
                }
                let missingSet = Set(missingIds)
                let missingGmailIds = (page.messages ?? []).map(\.id).filter { missingSet.contains($0) }
                // Batch HTTP when enabled; retry-exhausted ids retry next window pass.
                let report = try await client.getMessages(ids: missingGmailIds)
                for msg in report.messages {
                    let (message, attachments) = MessageParser.parse(msg, accountId: accountId)
                    writeBuffer.append(PendingUpsert(message: message, attachments: attachments))
                    if writeBuffer.count >= Self.writeChunkSize {
                        try await flushUpserts(&writeBuffer, into: &touchedKeys)
                    }
                }
                fetched += report.messages.count
                // "Fetched" not "Downloaded": up to writeChunkSize-1 may still be
                // buffered uncommitted; a failed final flush rolls those back.
                if fetched > 0 { progress?("Fetched \(fetched) messages…") }
                pageToken = page.nextPageToken
            } while pageToken != nil && listed < limit
            try await flushUpserts(&writeBuffer, into: &touchedKeys)
            return touchedKeys
        }
    }

    /// Returns gmailIds from `listed` that are not already stored for
    /// `accountId`. Uses primary-key lookups (`id = accountId:gmailId`) so
    /// work is O(|listed|), not O(all messages in the account).
    ///
    /// Dedupes `listed` while preserving first-seen order. Empty input → [].
    /// Extracted for unit tests (seed known ids; assert only missing returned).
    static func filterMissingGmailIds(_ db: Database, accountId: String,
                                      listed: [String]) throws -> [String] {
        guard !listed.isEmpty else { return [] }
        var seen = Set<String>()
        let unique = listed.filter { seen.insert($0).inserted }
        let localIds = unique.map { "\(accountId):\($0)" }
        let placeholders = localIds.map { _ in "?" }.joined(separator: ",")
        let existingLocal = try Set(String.fetchAll(
            db,
            sql: "SELECT id FROM message WHERE id IN (\(placeholders))",
            arguments: StatementArguments(localIds)))
        return unique.filter { !existingLocal.contains("\(accountId):\($0)") }
    }

    // MARK: - Incremental

    private func incrementalSync(since historyId: String, progress: (@Sendable (String) -> Void)?) async throws -> String {
        var pageToken: String?
        var latest = historyId
        // messagesAdded (and label changes for unknown local messages) need a
        // full getMessage; label-only changes on cached messages apply locally.
        var fullFetch = Set<String>()
        var deleted = Set<String>()
        // Ordered per-message label ops so add/remove sequences apply correctly.
        var labelOps: [String: [(add: [String], remove: [String])]] = [:]
        repeat {
            let page = try await client.history(since: historyId, pageToken: pageToken)
            for item in page.history ?? [] {
                for m in item.messagesAdded ?? [] { fullFetch.insert(m.message.id) }
                for m in item.labelsAdded ?? [] {
                    let id = m.message.id
                    if fullFetch.contains(id) { continue }
                    labelOps[id, default: []].append((add: m.labelIds ?? [], remove: []))
                }
                for m in item.labelsRemoved ?? [] {
                    let id = m.message.id
                    if fullFetch.contains(id) { continue }
                    labelOps[id, default: []].append((add: [], remove: m.labelIds ?? []))
                }
                for m in item.messagesDeleted ?? [] { deleted.insert(m.message.id) }
            }
            if let h = page.historyId { latest = h }
            pageToken = page.nextPageToken
        } while pageToken != nil

        fullFetch.subtract(deleted)
        for id in deleted { labelOps.removeValue(forKey: id) }
        for id in fullFetch { labelOps.removeValue(forKey: id) }

        // Collect the distinct thread keys affected by this batch so each
        // thread is re-derived exactly once, after all message upserts/
        // deletes for the batch are applied (rather than once per message).
        var touchedKeys = Set<String>()

        for id in deleted {
            let key = "\(accountId):\(id)"
            if let threadKey = try await db.write({ db -> String? in
                let threadKey = try String.fetchOne(db, sql:
                    "SELECT threadId FROM message WHERE id = ?", arguments: [key])
                _ = try Message.deleteOne(db, key: key)
                return threadKey
            }) {
                touchedKeys.insert(threadKey)
            }
        }

        // Label-only history: patch labelIds/isUnread in place when the
        // message is already cached; otherwise promote to a full fetch.
        // One write transaction for the whole batch (bulk mark-read etc.).
        var labelOnlyCount = 0
        if !labelOps.isEmpty {
            let opsSnapshot = labelOps
            let account = accountId
            let (patchedKeys, missing) = try await db.write { db -> (Set<String>, [String]) in
                var keys = Set<String>()
                var missing: [String] = []
                for (gmailId, ops) in opsSnapshot {
                    let key = "\(account):\(gmailId)"
                    guard var msg = try Message.fetchOne(db, key: key) else {
                        missing.append(gmailId)
                        continue
                    }
                    for op in ops {
                        msg.labelIds = Self.applyLabelDelta(labelIds: msg.labelIds,
                                                            add: op.add, remove: op.remove)
                    }
                    msg.isUnread = msg.labelIds.split(separator: " ").contains("UNREAD")
                    try msg.save(db)
                    keys.insert(msg.threadId)
                }
                return (keys, missing)
            }
            touchedKeys.formUnion(patchedKeys)
            labelOnlyCount = opsSnapshot.count - missing.count
            for id in missing { fullFetch.insert(id) }
        }

        // Batch or concurrent getMessages; buffer writes into chunks so
        // SQLCipher transaction overhead does not dominate.
        // Per-id 404s are skipped inside getMessagesConcurrent (not whole-batch).
        // HistoryFetchFormat picks full vs metadata when a local row already exists.
        // Failure mid-chunk rolls back that chunk only (earlier chunks stick).
        var writeBuffer: [PendingUpsert] = []
        writeBuffer.reserveCapacity(Self.writeChunkSize)
        let fullIds = Array(fullFetch)
        if !fullIds.isEmpty {
            let account = accountId
            // One read for local existence (same shape as filterMissingGmailIds).
            let existingLocal = try await db.read { db -> Set<String> in
                guard !fullIds.isEmpty else { return [] }
                let localIds = fullIds.map { "\(account):\($0)" }
                let placeholders = localIds.map { _ in "?" }.joined(separator: ",")
                return Set(try String.fetchAll(
                    db,
                    sql: "SELECT id FROM message WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(localIds)))
            }
            var needFull: [String] = []
            var needMeta: [String] = []
            needFull.reserveCapacity(fullIds.count)
            for gmailId in fullIds {
                let localExists = existingLocal.contains("\(account):\(gmailId)")
                // messagesAdded / never-cached → full; already-cached edge cases →
                // metadata only (must not wipe body — see upsertPending.headersOnly).
                switch HistoryFetchFormat.decide(
                    isMessagesAdded: !localExists,
                    localExists: localExists,
                    historyHasLabelIds: false,
                    needBody: !localExists
                ) {
                case .full:
                    needFull.append(gmailId)
                case .metadata:
                    needMeta.append(gmailId)
                case .skip:
                    break
                }
            }
            var retryExhausted = 0
            if !needFull.isEmpty {
                let report = try await client.getMessages(ids: needFull, format: "full")
                retryExhausted += report.retryExhaustedIds.count
                for msg in report.messages {
                    let (message, attachments) = MessageParser.parse(msg, accountId: accountId)
                    writeBuffer.append(PendingUpsert(
                        message: message, attachments: attachments, headersOnly: false))
                    if writeBuffer.count >= Self.writeChunkSize {
                        try await flushUpserts(&writeBuffer, into: &touchedKeys)
                    }
                }
            }
            if !needMeta.isEmpty {
                let report = try await client.getMessages(ids: needMeta, format: "metadata")
                retryExhausted += report.retryExhaustedIds.count
                for msg in report.messages {
                    let (message, _) = MessageParser.parse(msg, accountId: accountId)
                    // headersOnly: patch labels/headers only — never touch message_body
                    // or attachments (metadata has empty payload).
                    writeBuffer.append(PendingUpsert(
                        message: message, attachments: [], headersOnly: true))
                    if writeBuffer.count >= Self.writeChunkSize {
                        try await flushUpserts(&writeBuffer, into: &touchedKeys)
                    }
                }
            }
            // Apply what we have, then refuse to advance history past misses
            // so the next sync re-reads the same history range.
            try await flushUpserts(&writeBuffer, into: &touchedKeys)
            if !touchedKeys.isEmpty {
                try await deriveThreads(for: touchedKeys)
                progress?("Updated \(fullFetch.count + labelOnlyCount) messages")
            }
            if !deleted.isEmpty {
                try await removeOrphanedThreads()
            }
            if retryExhausted > 0 {
                PerfMetrics.measure(.syncHistoryPartial, meta: "failed=\(retryExhausted)") { () }
                progress?("Sync incomplete (\(retryExhausted) messages pending retry)…")
                throw GmailError.partialFetch(failedCount: retryExhausted)
            }
            return latest
        }
        try await flushUpserts(&writeBuffer, into: &touchedKeys)

        // Recompute thread rows for anything affected, exactly once each.
        if !touchedKeys.isEmpty {
            try await deriveThreads(for: touchedKeys)
            progress?("Updated \(fullFetch.count + labelOnlyCount) messages")
        }
        // A thread can lose all its messages (e.g. every message deleted);
        // drop those rows rather than leaving a stale thread behind.
        if !deleted.isEmpty {
            try await removeOrphanedThreads()
        }
        return latest
    }

    /// Merges label add/remove deltas into a space-separated labelIds string.
    /// Removes first, then adds. History events are applied in the order they
    /// were recorded (add-ops and remove-ops as separate sequential steps).
    /// Pure — unit-tested.
    static func applyLabelDelta(labelIds: String, add: [String], remove: [String]) -> String {
        var labels = Set(labelIds.split(separator: " ").map(String.init).filter { !$0.isEmpty })
        for r in remove where !r.isEmpty { labels.remove(r) }
        for a in add where !a.isEmpty { labels.insert(a) }
        return labels.sorted().joined(separator: " ")
    }

    // MARK: - Bounded concurrency

    /// Runs `fetch` over `ids` with at most `concurrency` tasks in flight.
    /// Each non-nil result is handed to `onValue` serially as it arrives
    /// (never from a concurrent child). Nil from `fetch` means "skip"
    /// (failed download). Empty `ids` is a no-op. Extracted so tests can
    /// inject a fetcher and assert peak concurrency + full coverage.
    static func withBoundedConcurrency<ID: Sendable, Value: Sendable>(
        ids: [ID],
        concurrency: Int = 8,
        fetch: @Sendable @escaping (ID) async -> Value?,
        onValue: (Value) async throws -> Void
    ) async rethrows {
        guard !ids.isEmpty else { return }
        let limit = max(1, concurrency)
        try await withThrowingTaskGroup(of: Value?.self) { group in
            var pending = 0
            var iterator = ids.makeIterator()
            func addNext() {
                if let id = iterator.next() {
                    group.addTask { await fetch(id) }
                    pending += 1
                }
            }
            for _ in 0..<min(limit, ids.count) { addNext() }
            while pending > 0 {
                let value = try await group.next()!
                pending -= 1
                if let value {
                    try await onValue(value)
                }
                addNext()
            }
        }
    }

    // MARK: - Local writes

    /// Messages per write transaction on backfill / full-fetch paths.
    /// Tuned to amortize SQLCipher commit cost without holding huge buffers.
    static let writeChunkSize = 32

    /// Parsed message + attachment rows ready for a batched local write.
    struct PendingUpsert {
        let message: Message
        let attachments: [AttachmentRow]
        /// When true (metadata-format history refresh), update the message row
        /// only — leave `message_body` and attachment rows untouched so a
        /// payload-less get cannot wipe already-cached bodies.
        var headersOnly: Bool = false
    }

    /// Writes a batch of messages (and attachments) in the caller's open
    /// transaction. Does NOT derive thread rows — callers batch that via
    /// `deriveThreads(for:)` once all messages in the sync pass are upserted.
    ///
    /// **Failure behavior:** if any row fails, the whole chunk rolls back with
    /// the transaction (earlier committed chunks are unaffected). Safe for
    /// retry of the failed chunk.
    ///
    /// Returns the set of thread keys touched. Empty `items` is a no-op.
    @discardableResult
    static func upsertPending(_ db: Database, items: [PendingUpsert]) throws -> Set<String> {
        var keys = Set<String>()
        for item in items {
            var msg = item.message
            if item.headersOnly {
                // Preserve body + attachments; keep hasAttachment if metadata
                // reported none (empty payload always looks attachment-free).
                if let existing = try Message.fetchOne(db, key: msg.id) {
                    if !msg.hasAttachment { msg.hasAttachment = existing.hasAttachment }
                }
                msg.bodyText = ""
                msg.bodyHTML = nil
                try msg.save(db)
                keys.insert(msg.threadId)
                continue
            }
            // Split body into message_body (v24); keep on-row columns empty so
            // header projections stay cheap under SQLCipher.
            let bodyText = msg.bodyText
            let bodyHTML = msg.bodyHTML
            msg.bodyText = ""
            msg.bodyHTML = nil
            try msg.save(db)
            try MessageBody(messageId: msg.id, bodyText: bodyText, bodyHTML: bodyHTML).save(db)
            try AttachmentRow.filter(Column("messageId") == item.message.id).deleteAll(db)
            for att in item.attachments {
                try att.insert(db)
            }
            keys.insert(item.message.threadId)
        }
        return keys
    }

    /// Commits `items` in one write transaction and unions thread keys into
    /// `touchedKeys`, then clears the buffer.
    private func flushUpserts(_ items: inout [PendingUpsert],
                              into touchedKeys: inout Set<String>) async throws {
        guard !items.isEmpty else { return }
        let batch = items  // copy: escaping write closure cannot capture inout
        let keys = try await PerfMetrics.measureAsync(.syncFlush, meta: "n=\(batch.count)") {
            try await db.write { db in
                try Self.upsertPending(db, items: batch)
            }
        }
        touchedKeys.formUnion(keys)
        items.removeAll(keepingCapacity: true)
    }

    /// Re-derives exactly the threads named by `keys` — once each — in a
    /// single write transaction. This is the batched replacement for calling
    /// per-message thread derivation once per touched message: however many
    /// messages in the sync batch belong to a given thread, that thread's
    /// row is fetched-and-saved exactly once. Static and takes an explicit
    /// `derivationCount` callback (invoked once per key) so tests can verify
    /// the collapse directly against an isolated in-memory database, the
    /// same pattern used by `pruneMessages`.
    private func deriveThreads(for keys: Set<String>) async throws {
        guard !keys.isEmpty else { return }
        try await db.write { [accountId] db in
            try Self.deriveThreads(db, for: keys, accountId: accountId)
        }
    }

    static func deriveThreads(_ db: Database, for keys: Set<String>, accountId: String,
                             derivationCount: (() -> Void)? = nil) throws {
        for threadKey in keys {
            let gmailThreadId = String(threadKey.split(separator: ":").last ?? "")
            let messages = try Message
                .filter(Column("threadId") == threadKey)
                .order(Column("date").desc)
                .fetchAll(db)
            let existing = try MailThread.fetchOne(db, key: threadKey)
            derivationCount?()
            guard let thread = deriveThread(
                threadKey: threadKey, gmailThreadId: gmailThreadId,
                accountId: accountId, messages: messages, existing: existing) else { continue }
            try thread.save(db)
            try ThreadLabels.rewrite(db, threadId: thread.id, labelIds: thread.labelIds)
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
            // Snippet/from still reflect the newest message (including your
            // own reply) so the row shows what just happened.
            snippet: newest.snippet,
            fromDisplay: MessageParser.displayName(fromHeader: newest.fromHeader),
            // Sort key deliberately ignores pure outbound (your reply/draft)
            // so sending does not jump the thread to the top of the inbox.
            lastDate: listSortDate(messages: messages, accountId: accountId),
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
            reminderSetAt: existing?.reminderSetAt,
            inSent: allLabels.contains("SENT"),
            inDrafts: allLabels.contains("DRAFT"),
            inPromotions: allLabels.contains("CATEGORY_PROMOTIONS"),
            inSocial: allLabels.contains("CATEGORY_SOCIAL"),
            inSpam: allLabels.contains("SPAM"),
            fromEmail: MessageParser.emailAddress(newest.fromHeader).lowercased(),
            allFromEmails: ThreadLabels.allFromEmails(from: messages)
        )
    }

    /// List sort key for a thread (messages newest-first).
    ///
    /// Own outbound rows — DRAFT, SENT-without-INBOX, or From matching the
    /// mailbox with no INBOX — do not advance the date when there is still
    /// inbound mail. Replying therefore leaves an inbox thread in place;
    /// only a real reply from someone else (or new inbound) moves it up.
    /// Pure-outbound threads (new compose, sent-only) fall back to newest.
    ///
    /// Also makes "remind if no reply" cancel on their reply, not on your
    /// own follow-up (`reminderSetAt` is compared to `lastDate`).
    static func listSortDate(messages: [Message], accountId: String) -> Date {
        guard let newest = messages.first else { return Date() }
        let account = accountId.lowercased()
        for m in messages {
            if isOwnOutbound(m, accountEmail: account) { continue }
            return m.date
        }
        return newest.date
    }

    /// True when this message should not move the thread's list position.
    static func isOwnOutbound(_ m: Message, accountEmail: String) -> Bool {
        let labs = Set(m.labelIds.split(whereSeparator: \.isWhitespace).map(String.init))
        if labs.contains("DRAFT") { return true }
        // Gmail marks your sends SENT and usually omits INBOX on the sent row.
        if labs.contains("SENT") && !labs.contains("INBOX") { return true }
        // From the mailbox primary without INBOX (some clients omit SENT).
        let from = MessageParser.emailAddress(m.fromHeader).lowercased()
        if from == accountEmail && !labs.contains("INBOX") { return true }
        return false
    }

    /// Recomputes every thread row for this account from scratch (used by
    /// schema-upgrade rebuilds and after a local prune, where the affected
    /// set is effectively "everything").
    private func rebuildThreads() async throws {
        let keys = try await db.read { [accountId] db in
            Set(try String.fetchAll(db, sql: """
                SELECT DISTINCT threadId FROM message WHERE accountId = ?
                """, arguments: [accountId]))
        }
        try await removeOrphanedThreads()
        try await deriveThreads(for: keys)
    }

    /// Deletes thread rows whose messages are all gone.
    private func removeOrphanedThreads() async throws {
        try await db.write { [accountId] db in
            try db.execute(sql: """
                DELETE FROM thread WHERE accountId = ?
                AND id NOT IN (SELECT DISTINCT threadId FROM message WHERE accountId = ?)
                """, arguments: [accountId, accountId])
        }
    }
}
