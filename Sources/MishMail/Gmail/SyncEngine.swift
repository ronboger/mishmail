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

    // MARK: - Reading-pane cache invalidation

    /// Thread ids whose *message* rows this engine rewrote since the last
    /// drain. Sync is the only writer of message rows — every other mutation
    /// (trash, archive, star, mark-read, labels) rewrites the thread row and
    /// leaves cached reading-pane bodies valid — so this is the complete set
    /// the payload cache needs to invalidate.
    private var touchedThreadIds = Set<String>()

    /// Rows were pruned or every thread re-derived. The touched set cannot
    /// describe *removals*, so the whole cache is suspect.
    private var contentFullyRebuilt = false

    /// What changed since the last drain. Clears the accumulator. Callers use
    /// this directly to collect partial work after `syncNow` throws.
    func drainContentChange() -> ThreadContentChange {
        defer {
            touchedThreadIds.removeAll(keepingCapacity: true)
            contentFullyRebuilt = false
        }
        if contentFullyRebuilt { return .everything }
        return touchedThreadIds.isEmpty ? .none : .threads(touchedThreadIds)
    }

    /// Returns which threads' reading-pane content this pass changed, so the
    /// caller can invalidate exactly those cached payloads.
    func syncNow(progress: (@Sendable (String) -> Void)? = nil) async throws
        -> ThreadContentChange {
        let account = try await db.read { [accountId] db in
            try Account.fetchOne(db, key: accountId)
        }
        guard var account else { return .none }

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
            return drainContentChange()
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
            let batch = try await fetchAll(query: windowQuery, limit: windowLimit, progress: progress)
            try await deriveThreads(for: batch.touchedKeys)
            if syncWindowDays != 0 {
                progress?("Removing local mail outside the window…")
                try await pruneLocalMail(keepingDays: syncWindowDays)
            }
            UserDefaults.standard.set(syncWindowDays, forKey: windowKey)
        }
        let starKey = "backfill.starred.\(accountId)"
        if !UserDefaults.standard.bool(forKey: starKey) {
            let batch = try await fetchAll(query: "is:starred", limit: 3000, progress: progress)
            try await deriveThreads(for: batch.touchedKeys)
            UserDefaults.standard.set(true, forKey: starKey)
        }

        // One-shot repair: older caches can hold a full body with hasAttachment=0
        // and zero attachment rows (metadata-wipe era, incomplete backfill, etc.).
        // Gmail's has:attachment list is the source of truth for which locals need
        // a full re-parse; filterMissingGmailIds never revisits existing ids.
        // Flag is only set when every page completed without retry exhaustion so
        // a rate-limited pass does not permanently strand unrepaired rows.
        let attachKey = Self.attachmentRepairDefaultsKey(accountId: accountId)
        if !UserDefaults.standard.bool(forKey: attachKey) {
            progress?("Repairing missing attachments…")
            let report = try await repairMissingAttachments(
                limit: windowLimit, progress: progress)
            try await deriveThreads(for: report.touchedKeys)
            if report.completedCleanly {
                UserDefaults.standard.set(true, forKey: attachKey)
            }
        }

        account.lastSyncAt = Date()
        let updated = account
        try await db.write { db in try updated.update(db) }
        return drainContentChange()
    }

    /// UserDefaults key for the one-shot has:attachment repair pass.
    static func attachmentRepairDefaultsKey(accountId: String) -> String {
        "backfill.attachments.\(accountId)"
    }

    /// True when this account has already completed the attachment repair pass.
    static func attachmentRepairCompleted(accountId: String,
                                          defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: attachmentRepairDefaultsKey(accountId: accountId))
    }

    /// Pure policy for whether the reading pane should re-fetch a message that
    /// has a body but no attachment rows. Unit-tested.
    ///
    /// - Cached `hasAttachment == true` with an empty chip list is always
    ///   worth repairing (wiped attachment table / denorm drift).
    /// - After the one-shot sync repair finishes for the account, skip opens
    ///   where `hasAttachment` is false — those are almost certainly clean
    ///   attachment-free mail, and re-fetching every one would thrash the API.
    /// - Before that pass, allow open-time recovery so stale rows (Criocore /
    ///   Let's chat) heal as soon as the user opens them.
    static func shouldRecoverAttachments(
        hasAttachmentFlag: Bool,
        localAttachmentCount: Int,
        accountRepairCompleted: Bool
    ) -> Bool {
        guard localAttachmentCount == 0 else { return false }
        if hasAttachmentFlag { return true }
        return !accountRepairCompleted
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
        let batch = try await fetchAll(query: windowQuery, limit: windowLimit, progress: progress)
        try await deriveThreads(for: batch.touchedKeys)
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

    /// Result of removing one local message row (discard / history delete).
    enum LocalMessageDeleteOutcome: Equatable {
        case missing
        case threadDeleted
        case threadRederived
    }

    /// Drop one message by local id, then either delete an empty thread or
    /// re-derive denorm flags. Hostless-testable; used by Discard before the
    /// remote drafts.delete so the card never sticks on a listDrafts miss.
    static func deleteLocalMessage(
        _ db: Database, messageId: String, threadId: String, accountId: String
    ) throws -> LocalMessageDeleteOutcome {
        guard try Message.fetchOne(db, key: messageId) != nil else { return .missing }
        _ = try Message.deleteOne(db, key: messageId)
        let remaining = try Message
            .filter(Column("threadId") == threadId)
            .fetchCount(db)
        if remaining == 0 {
            _ = try MailThread.deleteOne(db, key: threadId)
            try ThreadLabels.rewrite(db, threadId: threadId, labelIds: "")
            return .threadDeleted
        }
        try deriveThreads(db, for: [threadId], accountId: accountId)
        return .threadRederived
    }

    /// Outcome of a server-side search: cache invalidation keys plus the
    /// Gmail-ranked local thread ids (even for messages already cached).
    struct ServerSearchResult: Sendable {
        var change: ThreadContentChange
        /// `accountId:gmailThreadId` in Gmail list order, unique, capped at limit.
        var threadIds: [String]
    }

    /// Lists messages matching a query and downloads only the ones missing
    /// from the local cache.
    /// Server-side search: downloads messages matching a Gmail query that
    /// aren't already cached (so a search can reach mail outside the local sync
    /// window), then rebuilds the affected threads. Gmail's `q` syntax matches
    /// the app's search operators (from:/to:/subject:/is:/before:/after:…).
    ///
    /// `threadIds` preserves Gmail rank so callers (UI reload, MCP) can surface
    /// matches even when free-text FTS would miss body-only hits after download.
    func searchServer(query: String, limit: Int = 50) async throws
        -> ServerSearchResult {
        let batch = try await fetchAll(query: query, limit: limit, progress: nil)
        try await deriveThreads(for: batch.touchedKeys)
        return ServerSearchResult(
            change: drainContentChange(),
            threadIds: batch.matchedThreadIds)
    }

    /// Downloads messages matching `query` that aren't already cached.
    /// Returns touched thread keys (for re-derivation) and ordered local
    /// thread ids Gmail listed (for search result surfaces).
    ///
    /// Network: bounded concurrent `getMessage` (8). Writes: buffered and
    /// committed in chunks of `writeChunkSize` (one SQLCipher transaction per
    /// chunk). A failure mid-chunk rolls back that chunk only; earlier chunks
    /// stay committed. Progress reports download totals periodically per page.
    ///
    /// Existence: per list page, PK lookup for that page's ids only — never
    /// loads all account gmailIds into a Set (memory stays O(page), not O(mailbox)).
    private struct FetchAllBatch: Sendable {
        var touchedKeys: Set<String>
        var matchedThreadIds: [String]
    }

    @discardableResult
    private func fetchAll(query: String?, limit: Int,
                          progress: (@Sendable (String) -> Void)?) async throws -> FetchAllBatch {
        try await PerfMetrics.measureAsync(.syncFetchAll, meta: "limit=\(limit)") {
            var touchedKeys = Set<String>()
            var writeBuffer: [PendingUpsert] = []
            writeBuffer.reserveCapacity(Self.writeChunkSize)
            var pageToken: String?
            var listed = 0
            var fetched = 0
            var matchedGmailThreadIds: [String] = []
            var seenGmailThreads = Set<String>()
            repeat {
                let page = try await client.listMessages(query: query, pageToken: pageToken, maxResults: 100)
                let refs = page.messages ?? []
                let listedIds = refs.map(\.id)
                listed += listedIds.count
                // Preserve Gmail rank across pages; cap at `limit` unique threads.
                for ref in refs {
                    if matchedGmailThreadIds.count >= limit { break }
                    if seenGmailThreads.insert(ref.threadId).inserted {
                        matchedGmailThreadIds.append(ref.threadId)
                    }
                }
                // Per-page missing check (PK IN …) — avoids O(mailbox) Set at start.
                let missingIds = try await db.read { [accountId] db in
                    try Self.filterMissingGmailIds(db, accountId: accountId, listed: listedIds)
                }
                let missingSet = Set(missingIds)
                let missingGmailIds = listedIds.filter { missingSet.contains($0) }
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
            let localThreadIds = Self.localThreadIds(
                accountId: accountId, gmailThreadIds: matchedGmailThreadIds)
            return FetchAllBatch(touchedKeys: touchedKeys, matchedThreadIds: localThreadIds)
        }
    }

    /// Map bare Gmail thread ids to local `accountId:gmailThreadId` keys.
    /// Extracted for unit tests.
    static func localThreadIds(accountId: String, gmailThreadIds: [String]) -> [String] {
        gmailThreadIds.map { "\(accountId):\($0)" }
    }

    /// Ordered unique Gmail thread ids from list refs, capped at `limit`.
    /// Extracted for unit tests (Gmail rank preservation).
    static func orderedUniqueGmailThreadIds(
        from refs: [(id: String, threadId: String)], limit: Int
    ) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        out.reserveCapacity(min(limit, refs.count))
        for ref in refs {
            if out.count >= limit { break }
            if seen.insert(ref.threadId).inserted {
                out.append(ref.threadId)
            }
        }
        return out
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

    /// gmailIds from `listed` that exist locally for `accountId` with
    /// `hasAttachment = 0`. Those rows need a full re-fetch when Gmail says
    /// they have attachments. Dedupes preserving first-seen order.
    static func filterGmailIdsNeedingAttachmentRepair(
        _ db: Database, accountId: String, listed: [String]
    ) throws -> [String] {
        guard !listed.isEmpty else { return [] }
        var seen = Set<String>()
        let unique = listed.filter { seen.insert($0).inserted }
        let localIds = unique.map { "\(accountId):\($0)" }
        let placeholders = localIds.map { _ in "?" }.joined(separator: ",")
        let needsRepair = try Set(String.fetchAll(
            db,
            sql: """
                SELECT id FROM message
                WHERE id IN (\(placeholders)) AND hasAttachment = 0
                """,
            arguments: StatementArguments(localIds)))
        return unique.filter { needsRepair.contains("\(accountId):\($0)") }
    }

    /// Outcome of one-shot attachment repair: which threads changed, and
    /// whether every listed page finished without retry exhaustion / truncation.
    struct AttachmentRepairReport: Sendable {
        var touchedKeys: Set<String>
        /// True only when both sweeps finished (`pageToken == nil`) and no
        /// getMessages ids were retry-exhausted — safe to set the completed flag.
        var completedCleanly: Bool
    }

    /// Re-downloads Gmail `has:attachment` messages that are cached locally
    /// without attachment rows / hasAttachment.
    ///
    /// Two sweeps: (1) in-window `has:attachment`, (2) all-time starred
    /// `has:attachment` so starred mail kept outside the window is not stranded
    /// after the completed flag is set.
    private func repairMissingAttachments(
        limit: Int,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> AttachmentRepairReport {
        var touchedKeys = Set<String>()
        var writeBuffer: [PendingUpsert] = []
        writeBuffer.reserveCapacity(Self.writeChunkSize)
        var repaired = 0
        var exhausted = 0
        var completedCleanly = true

        // Windowed corpus + starred-all-time (starred mail is retained outside
        // the prune window and must not be skipped by the one-shot flag).
        let queries: [String] = {
            var qs: [String] = []
            if let window = windowQuery {
                qs.append("has:attachment \(window)")
            } else {
                qs.append("has:attachment")
            }
            qs.append("has:attachment is:starred")
            return qs
        }()

        for query in queries {
            var pageToken: String?
            var listed = 0
            repeat {
                let page = try await client.listMessages(
                    query: query, pageToken: pageToken, maxResults: 100)
                let listedIds = (page.messages ?? []).map(\.id)
                listed += listedIds.count
                let needRepair = try await db.read { [accountId] db in
                    try Self.filterGmailIdsNeedingAttachmentRepair(
                        db, accountId: accountId, listed: listedIds)
                }
                if !needRepair.isEmpty {
                    let report = try await client.getMessages(
                        ids: needRepair, format: "full")
                    exhausted += report.retryExhaustedIds.count
                    for msg in report.messages {
                        let (message, attachments) = MessageParser.parse(
                            msg, accountId: accountId)
                        writeBuffer.append(PendingUpsert(
                            message: message, attachments: attachments,
                            headersOnly: false))
                        if writeBuffer.count >= Self.writeChunkSize {
                            try await flushUpserts(&writeBuffer, into: &touchedKeys)
                        }
                    }
                    repaired += report.messages.count
                    progress?("Repaired attachments on \(repaired) messages…")
                }
                pageToken = page.nextPageToken
                if listed >= limit && pageToken != nil {
                    // Hit the listed-id cap with more pages remaining — do not
                    // claim the pass finished cleanly.
                    completedCleanly = false
                    break
                }
            } while pageToken != nil
        }
        try await flushUpserts(&writeBuffer, into: &touchedKeys)
        if exhausted > 0 { completedCleanly = false }
        return AttachmentRepairReport(
            touchedKeys: touchedKeys, completedCleanly: completedCleanly)
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
        // Single choke point for message-row writes: everything that rewrites
        // messages re-derives their threads here, so recording the keys once
        // covers backfill, history catch-up, window changes and search.
        touchedThreadIds.formUnion(keys)
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
        // Primary vs Promotions/Social tabs: newest INBOX-bearing message wins.
        // Union of all historical labels would pin a personal reply under
        // Promotions forever when an older archived invite still carries
        // CATEGORY_PROMOTIONS (Gmail Primary surfaces the conversation).
        let tabs = tabCategoryFlags(messages: messages)

        // Participants in chronological order, deduped, own account as "me".
        var seen = Set<String>()
        var participants: [String] = []
        for m in messages.reversed() {
            let sender = MessageParser.emailAddress(m.fromHeader)
            let name = sender == accountId ? "me" : MessageParser.displayName(fromHeader: m.fromHeader)
            let short = name.split(separator: " ").first.map(String.init) ?? name
            if seen.insert(short).inserted { participants.append(short) }
        }

        // Discarded drafts are DRAFT+TRASH on individual messages. A naive
        // union would pin inTrash and hide the live conversation from Inbox
        // (Anna / Fund Expense case). Same for inDrafts — only live drafts.
        let trashDraft = trashDraftFlags(messages: messages)

        return MailThread(
            id: threadKey,
            accountId: accountId,
            gmailThreadId: gmailThreadId,
            subject: messages.last?.subject.isEmpty == false ? messages.last!.subject : newest.subject,
            snippet: newest.snippet,
            fromDisplay: MessageParser.displayName(fromHeader: newest.fromHeader),
            // Newest any message — Sent/Drafts/search/row timestamps need this.
            lastDate: newest.date,
            isUnread: messages.contains { $0.isUnread },
            isStarred: allLabels.contains("STARRED"),
            inInbox: allLabels.contains("INBOX"),
            inTrash: trashDraft.inTrash,
            // Full union still powers search / label chips; tab denorm is separate.
            labelIds: allLabels.sorted().joined(separator: " "),
            // Local snooze; Gmail-style wake on new *inbound* activity only.
            snoozeUntil: preservedSnoozeUntil(
                existing: existing, messages: messages, accountId: accountId),
            participants: participants.joined(separator: " .. "),
            messageCount: messages.count,
            hasAttachment: messages.contains { $0.hasAttachment },
            reminderAt: existing?.reminderAt,
            reminderSetAt: existing?.reminderSetAt,
            inSent: allLabels.contains("SENT"),
            inDrafts: trashDraft.inDrafts,
            inPromotions: tabs.promotions,
            inSocial: tabs.social,
            inSpam: allLabels.contains("SPAM"),
            fromEmail: MessageParser.emailAddress(newest.fromHeader).lowercased(),
            allFromEmails: ThreadLabels.allFromEmails(from: messages),
            // Inbox-only sort / remind-if-no-reply. Nil when pure outbound so
            // own follow-ups never look like "they replied."
            lastInboundDate: lastInboundDate(messages: messages, accountId: accountId)
        )
    }

    /// Thread-level trash / drafts denorm from per-message labels.
    ///
    /// Gmail keeps discarded drafts as `DRAFT TRASH` on those messages while
    /// the conversation stays in Inbox. A historical union of TRASH would hide
    /// the thread from Inbox / All Mail / badges (`inInbox && !inTrash`).
    ///
    /// - **inTrash**: any non-draft TRASH message, or every message is trashed
    ///   (covers discarded-compose-only threads that never left drafts).
    /// - **inDrafts**: any live draft (`DRAFT` without `TRASH`).
    /// Pure — unit-tested. Also used by migration v30.
    static func trashDraftFlags(messages: [Message]) -> (inTrash: Bool, inDrafts: Bool) {
        trashDraftFlags(labelIdStrings: messages.map(\.labelIds))
    }

    /// Same rule as `trashDraftFlags(messages:)`, taking space-separated
    /// `labelIds` strings. Used by migration v30 so it never decodes the live
    /// `Message` record against a frozen schema.
    static func trashDraftFlags(labelIdStrings: [String]) -> (inTrash: Bool, inDrafts: Bool) {
        guard !labelIdStrings.isEmpty else { return (false, false) }
        var anyLiveDraft = false
        var anyNonDraftTrash = false
        var anyTrash = false
        var allTrashed = true
        for s in labelIdStrings {
            let labs = Set(s.split(whereSeparator: \.isWhitespace).map(String.init))
            let hasTrash = labs.contains("TRASH")
            let hasDraft = labs.contains("DRAFT")
            if hasDraft && !hasTrash { anyLiveDraft = true }
            if hasTrash && !hasDraft { anyNonDraftTrash = true }
            if hasTrash { anyTrash = true } else { allTrashed = false }
        }
        return (
            inTrash: anyNonDraftTrash || (anyTrash && allTrashed),
            inDrafts: anyLiveDraft
        )
    }

    /// Local `snoozeUntil` across re-derives, with Gmail-style wake-on-reply.
    ///
    /// MishMail snooze is client-side (API has no snooze field). Clears when:
    /// - **Inbound advances** (`lastInboundDate`) — reply while sleeping.
    /// - **Ghost heal**: pre-fix rows kept `snoozeUntil` after a reply
    ///   re-added INBOX (`inInbox == true` while still "sleeping"). MishMail
    ///   snooze always strips INBOX, so that combo means already woken.
    /// Does not clear on draft saves, pure SENT, or prune→backfill count churn.
    /// Pure — unit-tested.
    static func preservedSnoozeUntil(
        existing: MailThread?, messages: [Message], accountId: String
    ) -> Date? {
        guard let existing, let until = existing.snoozeUntil else { return nil }
        // Pre-fix ghost: reply restored INBOX but left snoozeUntil set.
        if existing.inInbox { return nil }
        let inbound = lastInboundDate(messages: messages, accountId: accountId)
        guard let inbound else { return until }  // still pure outbound
        if let prior = existing.lastInboundDate {
            // Strictly newer inbound → wake (reply arrived while sleeping).
            if inbound > prior { return nil }
            return until
        }
        // Was pure outbound when snoozed; first inbound wakes.
        return nil
    }

    /// Tab placement for Promotions / Social (Primary inbox hides both).
    ///
    /// Uses the **newest message that currently has INBOX**. Gmail keeps
    /// `CATEGORY_PROMOTIONS` on old no-reply invites after a human reply
    /// re-adds INBOX only on the new messages; Primary should follow the live
    /// inbox-bearing classification, not the historical union.
    ///
    /// When nothing has INBOX (fully archived / trash-only / spam-only), falls
    /// back to the newest message so All Mail and category chips stay coherent.
    /// `messages` must be newest-first (same order as `deriveThread`).
    /// Pure — unit-tested.
    static func tabCategoryFlags(messages: [Message]) -> (promotions: Bool, social: Bool) {
        tabCategoryFlags(labelIdStrings: messages.map(\.labelIds))
    }

    /// Same rule as `tabCategoryFlags(messages:)`, taking space-separated
    /// `labelIds` strings newest-first. Used by migration v27 so it never
    /// decodes the live `Message` record against a frozen schema.
    /// Pure — unit-tested.
    static func tabCategoryFlags(labelIdStrings: [String]) -> (promotions: Bool, social: Bool) {
        guard !labelIdStrings.isEmpty else { return (false, false) }
        let source = labelIdStrings.first(where: { labelIdsContain($0, "INBOX") })
            ?? labelIdStrings[0]
        return (
            promotions: labelIdsContain(source, "CATEGORY_PROMOTIONS"),
            social: labelIdsContain(source, "CATEGORY_SOCIAL")
        )
    }

    /// Token match on a space-separated `labelIds` string (not substring).
    static func labelIdsContain(_ labelIds: String, _ label: String) -> Bool {
        labelIds.split(whereSeparator: \.isWhitespace).contains { $0 == label }
    }

    /// Newest non-outbound message date, or nil when the thread is pure
    /// outbound (new compose / sent-only). Messages newest-first.
    static func lastInboundDate(messages: [Message], accountId: String) -> Date? {
        let account = accountId.lowercased()
        for m in messages {
            if isOwnOutbound(m, accountEmail: account) { continue }
            return m.date
        }
        return nil
    }

    /// True when this message should not move inbox position or cancel a
    /// "remind if no reply" timer. Pure outbound only — SENT+INBOX (self
    /// echo / reply-all including you) still counts as activity.
    static func isOwnOutbound(_ m: Message, accountEmail: String) -> Bool {
        let labs = Set(m.labelIds.split(whereSeparator: \.isWhitespace).map(String.init))
        if labs.contains("DRAFT") { return true }
        // Gmail marks your sends SENT and usually omits INBOX on the sent row.
        if labs.contains("SENT") && !labs.contains("INBOX") { return true }
        // From the mailbox primary without INBOX (some clients omit SENT).
        // Send-as aliases rely on the SENT label above — MailStore's identity
        // list is not available inside pure derive.
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
        // The surviving keys say nothing about the threads that were just
        // pruned away, so their cached payloads can only be dropped wholesale.
        contentFullyRebuilt = true
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
