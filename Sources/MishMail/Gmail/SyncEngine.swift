import Foundation
import GRDB

/// Per-account sync: initial backfill via messages.list, then cheap
/// incremental catch-up via history.list keyed on the stored historyId.
actor SyncEngine {
    private let client: GmailClient
    private let accountId: String
    private let db = AppDatabase.shared.dbPool
    /// Serializes passes. A caller that arrives mid-pass waits for one
    /// shared follow-up pass, so its own change is never answered by a pass
    /// that started before it.
    private let passes = CoalescingRunner<ThreadContentChange>()

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
        self.client = GmailClient.shared(accountEmail: accountId)
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
    ///
    /// A call made while a pass is running waits for the next pass (shared by
    /// every caller that arrives meanwhile) instead of joining the running
    /// one, whose result may predate the caller's change.
    func syncNow(progress: (@Sendable (String) -> Void)? = nil) async throws
        -> ThreadContentChange {
        try await passes.run { [weak self] in
            guard let self else { return .none }
            return try await self.performSyncNow(progress: progress)
        }
    }

    /// Cancels the running pass and any queued follow-up, and returns once
    /// both have ended. Used before the account's rows are deleted.
    func cancelSync() async {
        await passes.cancelAll()
    }

    private func performSyncNow(progress: (@Sendable (String) -> Void)? = nil) async throws
        -> ThreadContentChange {
        let account = try await db.read { [accountId] db in
            try Account.fetchOne(db, key: accountId)
        }
        guard let account else { return .none }

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
            try await db.write { [accountId] db in
                try db.execute(
                    sql: "UPDATE account SET historyId = NULL, lastSyncAt = ? WHERE id = ?",
                    arguments: [Date(), accountId])
            }
            return drainContentChange()
        }

        if let historyId = account.historyId {
            do {
                let latest = try await incrementalSync(since: historyId, progress: progress)
                try await commitHistoryId(latest)
            } catch GmailError.historyExpired {
                let latest = try await fullBackfill(
                    reconcileCached: true, progress: progress)
                try await commitHistoryId(latest)
            }
        } else {
            let latest = try await fullBackfill(progress: progress)
            try await commitHistoryId(latest)
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

        try await commitAccountState(lastSyncAt: Date())
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
            try Self.applyLabels(db, accountId: accountId, labels: labels)
        }
    }

    /// Makes this account's label rows match Gmail's label list: inserts
    /// new labels, updates changed ones, and deletes rows whose label Gmail
    /// no longer lists (deleted in Gmail). Other accounts are not touched.
    ///
    /// An empty list deletes nothing: every mailbox has system labels, so
    /// an empty answer is a bad response, not "all labels deleted".
    /// Exercised directly by the test suite.
    static func applyLabels(_ db: Database, accountId: String, labels: [GLabel]) throws {
        for l in labels {
            let id = "\(accountId):\(l.id)"
            // Color and order are local customizations — a resync must
            // never wipe them. Gmail's own label color only seeds a label
            // that has no local color yet.
            let existing = try LabelRow.fetchOne(db, key: id)
            let row = LabelRow(id: id, accountId: accountId,
                               gmailLabelId: l.id, name: l.name, type: l.type ?? "user",
                               color: existing?.color ?? l.color?.backgroundColor,
                               sortOrder: existing?.sortOrder ?? LabelRow.unsorted)
            // Runs every pass, and labels almost never change between
            // passes — write only rows that differ from the stored one.
            if row != existing { try row.save(db) }
        }
        guard !labels.isEmpty else { return }
        // Compared in memory, not with `NOT IN (…)`: the fetched list can
        // exceed what one statement binds.
        let fetched = Set(labels.map(\.id))
        let stored = try String.fetchAll(
            db, sql: "SELECT gmailLabelId FROM label WHERE accountId = ?",
            arguments: [accountId])
        let gone = stored.filter { !fetched.contains($0) }.map { "\(accountId):\($0)" }
        for chunk in sqlChunks(gone) {
            try db.execute(
                sql: "DELETE FROM label WHERE accountId = ? AND id IN (\(placeholders(chunk.count)))",
                arguments: StatementArguments([accountId] + Array(chunk)))
        }
    }

    // MARK: - Backfill

    private func fullBackfill(reconcileCached: Bool = false,
                              progress: (@Sendable (String) -> Void)?) async throws -> String {
        // Read before listing: history from this id onward replays anything
        // that changes while the backfill runs.
        let profile = try await client.profile()
        let batch = try await fetchAll(query: windowQuery, limit: windowLimit, progress: progress)
        try await deriveThreads(for: batch.touchedKeys)
        UserDefaults.standard.set(syncWindowDays, forKey: "backfill.window.\(accountId)")
        if reconcileCached {
            let plan = try await removeStaleCachedMessages(
                listedGmailIds: batch.listedGmailIds,
                listingComplete: batch.listingComplete)
            // History expired, the snapshot is downloaded and rows Gmail no
            // longer lists are gone. Commit the new history id NOW, before
            // the label refresh below. Rationale: history from
            // `profile.historyId` onward still delivers every later change,
            // so the next pass is incremental. If this commit waited for the
            // refresh and the refresh hit the quota, the id would stay
            // expired and every pass would restart the full reconcile and
            // lose its work — an infinite loop. Stale labels on a few cached
            // rows (until they next change) are the lesser evil.
            try await commitHistoryId(profile.historyId)
            await refreshCachedLabels(
                plan, skipping: batch.downloadedGmailIds, progress: progress)
        }
        return profile.historyId
    }

    /// Cached rows the history-expired reconcile must re-read by id.
    /// Most metadata gets one expired-history reconcile spends on labels.
    static let maxReconcileLabelRefresh = 2_000

    private struct ReconcilePlan: Sendable {
        /// Every cached row inside the window: (local id, gmail id, thread key).
        var rows: [(id: String, gmailId: String, threadId: String)]
        /// Gmail ids whose labels need a metadata refresh.
        var metadataIds: [String]
    }

    /// History expiration makes the mailbox snapshot authoritative again. In
    /// addition to downloading missing rows, re-list system-label views so an
    /// already-cached message can lose INBOX/UNREAD/STARRED/TRASH/SPAM labels.
    ///
    /// A cached row missing from the listings is deleted only when every
    /// listing ran to its last page. A listing cut off by `windowLimit` says
    /// nothing about the rows past the cap, so those rows are re-read by id
    /// instead (a 404 then deletes them).
    ///
    /// Deletes the stale rows and settles their threads right away, then
    /// returns the rows whose labels still need a refresh.
    private func removeStaleCachedMessages(listedGmailIds initialIds: Set<String>,
                                           listingComplete initialComplete: Bool) async throws
        -> ReconcilePlan {
        var listed = initialIds
        var listingComplete = initialComplete
        for label in ["INBOX", "UNREAD", "STARRED", "TRASH", "SPAM"] {
            let query = label == "STARRED" ? nil : windowQuery
            let page = try await listAllGmailIds(
                query: query, labelIds: [label], limit: windowLimit,
                includeSpamTrash: label == "TRASH" || label == "SPAM")
            listed.formUnion(page.ids)
            listingComplete = listingComplete && page.complete
        }

        let days = syncWindowDays
        let rows = try await db.read { [accountId, days] db -> [(id: String, gmailId: String, threadId: String)] in
            let predicate = days == 0
                ? ""
                : "AND (date >= ? OR (' ' || labelIds || ' ') LIKE '% STARRED %')"
            var args: [Any] = [accountId]
            if days != 0 {
                args.append(Date().addingTimeInterval(-Double(days) * 86_400))
            }
            return try Row.fetchAll(db, sql: """
                SELECT id, gmailId, threadId FROM message
                WHERE accountId = ? \(predicate)
                """, arguments: StatementArguments(args) ?? StatementArguments()).map { row in
                    (id: row["id"] as String,
                     gmailId: row["gmailId"] as String,
                     threadId: row["threadId"] as String)
                }
        }
        let stale = listingComplete ? rows.filter { !listed.contains($0.gmailId) } : []
        let metadataIds = listingComplete
            ? rows.filter { listed.contains($0.gmailId) }.map { $0.gmailId }
            : rows.map { $0.gmailId }

        if !stale.isEmpty {
            let staleKeys = Set(stale.map { $0.threadId })
            try await deleteMessages(localIds: stale.map { $0.id })
            try await settleThreads(staleKeys)
        }
        return ReconcilePlan(rows: rows, metadataIds: metadataIds)
    }

    /// Best-effort label refresh for cached rows after a history-expired
    /// reconcile. The history id is already committed, so this never throws:
    /// whatever lands is written, a rate-limited remainder is logged and left
    /// for later history to correct, and a failed request is logged too.
    private func refreshCachedLabels(_ plan: ReconcilePlan, skipping downloaded: Set<String>,
                                     progress: (@Sendable (String) -> Void)?) async {
        // Rows fetchAll just downloaded in full already carry fresh labels.
        // Capped: at 5 units a get, 50k cached rows would hold the sync
        // runner (and every send waiting on it) for ~20 minutes. Labels past
        // the cap stay as cached until history next touches them.
        let ids = Array(Set(plan.metadataIds).subtracting(downloaded)
            .prefix(Self.maxReconcileLabelRefresh))
        guard !ids.isEmpty else { return }
        do {
            let report = try await client.getMessages(ids: ids, format: "metadata")
            var touchedKeys = Set<String>()
            // Parsed off this actor, in parallel, results in input order.
            let pending = await MessageParser.parseConcurrently(
                report.messages, accountId: accountId
            ).map { parsed, _ in
                PendingUpsert(message: parsed, attachments: [], headersOnly: true)
            }
            if !pending.isEmpty {
                let keys = try await db.write { db in
                    try Self.upsertPending(db, items: pending)
                }
                touchedKeys.formUnion(keys)
            }
            let missing = Set(report.notFoundIds)
            if !missing.isEmpty {
                let missingRows = plan.rows.filter { missing.contains($0.gmailId) }
                touchedKeys.formUnion(missingRows.map { $0.threadId })
                try await deleteMessages(localIds: missingRows.map { $0.id })
            }
            try await settleThreads(touchedKeys)
            if report.hasRetryExhausted {
                PerfMetrics.measure(
                    .syncReconcilePartial,
                    meta: "labels pending=\(report.retryExhaustedIds.count) of=\(ids.count)") { () }
                progress?("Some labels will refresh later…")
            }
        } catch {
            PerfMetrics.measure(
                .syncReconcilePartial,
                meta: "labels failed=\(ids.count) error=\(error.localizedDescription)") { () }
        }
    }

    /// Re-derives `keys` and drops any of them left without messages.
    private func settleThreads(_ keys: Set<String>) async throws {
        guard !keys.isEmpty else { return }
        try await deriveThreads(for: keys)
        try await removeOrphanedThreads(for: keys)
    }

    private func listAllGmailIds(query: String?, labelIds: [String], limit: Int,
                                 includeSpamTrash: Bool = false) async throws
        -> (ids: Set<String>, complete: Bool) {
        var result = Set<String>()
        var pageToken: String?
        var listed = 0
        repeat {
            // Ids only — no per-page downloads — so the largest page Gmail
            // allows: a fifth of the list calls for a reconcile listing.
            let page = try await client.listMessages(
                query: query, labelIds: labelIds, pageToken: pageToken,
                maxResults: GmailClient.maxListPageSize,
                includeSpamTrash: includeSpamTrash)
            let ids = (page.messages ?? []).map(\.id)
            result.formUnion(ids)
            listed += ids.count
            pageToken = page.nextPageToken
        } while pageToken != nil && listed < limit
        return (result, pageToken == nil)
    }

    /// Deletes message rows by local id in bounded statements (SQLite caps
    /// the number of bound variables per statement).
    private func deleteMessages(localIds: [String]) async throws {
        guard !localIds.isEmpty else { return }
        try await db.write { db in
            _ = try Self.deleteMessages(db, localIds: localIds)
        }
    }

    // MARK: - Bounded SQL

    /// Most `?` placeholders one statement binds. SQLite rejects a statement
    /// past its variable limit (32766), and a large Gmail-side delete or a
    /// full reconcile can name far more ids than that.
    static let sqlBindChunkSize = 500

    /// `messages.list` page size for a loop that stops once `listed`
    /// reaches `limit`: Gmail's maximum, but never more than what is left,
    /// so a bigger page cannot overshoot the cap. At least 1.
    static func listPageSize(listed: Int, limit: Int) -> Int {
        max(1, min(GmailClient.maxListPageSize, limit - listed))
    }

    /// Splits `items` into runs of at most `sqlBindChunkSize`.
    static func sqlChunks<T>(_ items: [T]) -> [ArraySlice<T>] {
        stride(from: 0, to: items.count, by: sqlBindChunkSize).map {
            items[$0..<min($0 + sqlBindChunkSize, items.count)]
        }
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    /// Local message ids from `localIds` that exist. Chunked.
    static func existingMessageIds(_ db: Database, localIds: [String]) throws -> Set<String> {
        var found = Set<String>()
        for chunk in sqlChunks(localIds) {
            found.formUnion(try String.fetchAll(
                db,
                sql: "SELECT id FROM message WHERE id IN (\(placeholders(chunk.count)))",
                arguments: StatementArguments(Array(chunk))))
        }
        return found
    }

    /// Deletes message rows by local id in chunks and returns the distinct
    /// thread keys the deleted rows belonged to.
    @discardableResult
    static func deleteMessages(_ db: Database, localIds: [String]) throws -> Set<String> {
        var keys = Set<String>()
        for chunk in sqlChunks(localIds) {
            let ids = Array(chunk)
            let marks = placeholders(ids.count)
            keys.formUnion(try String.fetchAll(
                db,
                sql: "SELECT DISTINCT threadId FROM message WHERE id IN (\(marks))",
                arguments: StatementArguments(ids)))
            try db.execute(sql: "DELETE FROM message WHERE id IN (\(marks))",
                           arguments: StatementArguments(ids))
        }
        return keys
    }

    /// Deletes this account's thread rows named in `keys` that no longer
    /// have any message. Chunked.
    static func removeOrphanedThreads(_ db: Database, accountId: String,
                                      keys: Set<String>) throws {
        for chunk in sqlChunks(Array(keys)) {
            try db.execute(sql: """
                DELETE FROM thread
                WHERE accountId = ? AND id IN (\(placeholders(chunk.count)))
                  AND NOT EXISTS (
                      SELECT 1 FROM message
                      WHERE message.threadId = thread.id
                  )
                """, arguments: StatementArguments([accountId] + Array(chunk)))
        }
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
        var listedGmailIds: Set<String>
        /// The listing reached its last page (not cut off by `limit`).
        var listingComplete: Bool
        /// Gmail ids downloaded in full by this call (fresh labels).
        var downloadedGmailIds: Set<String>
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
            var retryExhausted = 0
            var listedGmailIds = Set<String>()
            var reachedLastPage = false
            var matchedGmailThreadIds: [String] = []
            var seenGmailThreads = Set<String>()
            var downloadedGmailIds = Set<String>()
            repeat {
                // Larger pages mean fewer list calls; capped at what is left
                // of `limit` so a page never lists (and so downloads) past it.
                let page = try await client.listMessages(
                    query: query, pageToken: pageToken,
                    maxResults: Self.listPageSize(listed: listed, limit: limit))
                let refs = page.messages ?? []
                let listedIds = refs.map(\.id)
                listedGmailIds.formUnion(listedIds)
                listed += listedIds.count
                // Preserve Gmail rank across pages; cap at `limit` unique threads.
                Self.appendUniqueGmailThreadIds(
                    into: &matchedGmailThreadIds,
                    seen: &seenGmailThreads,
                    from: refs.map { ($0.id, $0.threadId) },
                    limit: limit)
                // Per-page missing check (PK IN …) — avoids O(mailbox) Set at start.
                let missingIds = try await db.read { [accountId] db in
                    try Self.filterMissingGmailIds(db, accountId: accountId, listed: listedIds)
                }
                let missingSet = Set(missingIds)
                let missingGmailIds = listedIds.filter { missingSet.contains($0) }
                // Batch HTTP when enabled; retry-exhausted ids retry next window pass.
                let report = try await client.getMessages(ids: missingGmailIds)
                // Parse off this actor, in parallel, one slice at a time; the
                // loop then only buffers and flushes, in fetch order. Slicing
                // bounds how many parsed bodies (HTML plus inlined CID images)
                // are alive at once — a whole 500-message page would be.
                for range in Self.parseSliceRanges(count: report.messages.count) {
                    let slice = Array(report.messages[range])
                    let parsedSlice = await MessageParser.parseConcurrently(
                        slice, accountId: accountId)
                    for (msg, (message, attachments)) in zip(slice, parsedSlice) {
                        downloadedGmailIds.insert(msg.id)
                        writeBuffer.append(PendingUpsert(message: message, attachments: attachments))
                        if writeBuffer.count >= Self.writeChunkSize {
                            try await flushUpserts(&writeBuffer, into: &touchedKeys)
                        }
                    }
                }
                fetched += report.messages.count
                retryExhausted += report.retryExhaustedIds.count
                // "Fetched" not "Downloaded": up to writeChunkSize-1 may still be
                // buffered uncommitted; a failed final flush rolls those back.
                if fetched > 0 { progress?("Fetched \(fetched) messages…") }
                if report.hasRetryExhausted {
                    // A rate-limited batch reports the remaining ids instead
                    // of fanning them out as singles. Do not list later pages:
                    // advancing through them would strand this page forever.
                    pageToken = nil
                } else {
                    pageToken = page.nextPageToken
                    reachedLastPage = page.nextPageToken == nil
                }
            } while pageToken != nil && listed < limit
            try await flushUpserts(&writeBuffer, into: &touchedKeys)
            if retryExhausted > 0 {
                // Settle the threads of what landed before throwing: the next
                // pass skips these now-cached ids, so nothing else would
                // derive their thread rows.
                try await deriveThreads(for: touchedKeys)
                throw GmailError.partialFetch(failedCount: retryExhausted)
            }
            let localThreadIds = Self.localThreadIds(
                accountId: accountId, gmailThreadIds: matchedGmailThreadIds)
            return FetchAllBatch(
                touchedKeys: touchedKeys, matchedThreadIds: localThreadIds,
                listedGmailIds: listedGmailIds, listingComplete: reachedLastPage,
                downloadedGmailIds: downloadedGmailIds)
        }
    }

    /// Map bare Gmail thread ids to local `accountId:gmailThreadId` keys.
    /// Extracted for unit tests.
    static func localThreadIds(accountId: String, gmailThreadIds: [String]) -> [String] {
        gmailThreadIds.map { "\(accountId):\($0)" }
    }

    /// Append ordered unique Gmail thread ids from list refs into `out`,
    /// respecting an existing cross-page `seen` set and a hard `limit`.
    /// Used by `fetchAll` (production) and covered by unit tests.
    static func appendUniqueGmailThreadIds(
        into out: inout [String],
        seen: inout Set<String>,
        from refs: [(id: String, threadId: String)],
        limit: Int
    ) {
        guard limit > 0 else { return }
        for ref in refs {
            if out.count >= limit { return }
            if seen.insert(ref.threadId).inserted {
                out.append(ref.threadId)
            }
        }
    }

    /// Ordered unique Gmail thread ids from list refs, capped at `limit`.
    static func orderedUniqueGmailThreadIds(
        from refs: [(id: String, threadId: String)], limit: Int
    ) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        out.reserveCapacity(min(max(limit, 0), refs.count))
        appendUniqueGmailThreadIds(into: &out, seen: &seen, from: refs, limit: limit)
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
        let existingLocal = try existingMessageIds(
            db, localIds: unique.map { "\(accountId):\($0)" })
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
        var needsRepair = Set<String>()
        for chunk in sqlChunks(unique.map { "\(accountId):\($0)" }) {
            needsRepair.formUnion(try String.fetchAll(
                db,
                sql: """
                    SELECT id FROM message
                    WHERE id IN (\(placeholders(chunk.count))) AND hasAttachment = 0
                    """,
                arguments: StatementArguments(Array(chunk))))
        }
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
                // Most listed ids already have their attachments, so this
                // loop is mostly paging; capped at what is left of `limit`.
                let page = try await client.listMessages(
                    query: query, pageToken: pageToken,
                    maxResults: Self.listPageSize(listed: listed, limit: limit))
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
                    for range in Self.parseSliceRanges(count: report.messages.count) {
                        let slice = Array(report.messages[range])
                        let parsedSlice = await MessageParser.parseConcurrently(
                            slice, accountId: accountId)
                        for (message, attachments) in parsedSlice {
                            writeBuffer.append(PendingUpsert(
                                message: message, attachments: attachments,
                                headersOnly: false))
                            if writeBuffer.count >= Self.writeChunkSize {
                                try await flushUpserts(&writeBuffer, into: &touchedKeys)
                            }
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

    /// Changed messages per committed slice. Small enough that one slice
    /// fits well inside Gmail's per-second budget even at 5 units a message.
    static let historySliceMessages = 100

    private func incrementalSync(since historyId: String, progress: (@Sendable (String) -> Void)?) async throws -> String {
        var pageToken: String?
        var latest = historyId
        var items: [GHistoryList.Item] = []
        repeat {
            let page = try await client.history(since: historyId, pageToken: pageToken)
            items += page.history ?? []
            if let h = page.historyId { latest = h }
            pageToken = page.nextPageToken
        } while pageToken != nil

        // Commit after every slice: a rate limit later in the run then costs
        // one slice, not the whole range, and the next pass resumes from
        // the last committed record instead of replaying everything.
        let records = items.enumerated().map { index, item in
            HistorySlicer.Record(
                id: item.id,
                addedIds: (item.messagesAdded ?? []).map(\.message.id),
                labelChangedIds: ((item.labelsAdded ?? []) + (item.labelsRemoved ?? [])).map(\.message.id),
                deletedIds: (item.messagesDeleted ?? []).map(\.message.id),
                index: index)
        }
        let slices = HistorySlicer.slices(records, maxMessages: Self.historySliceMessages)
        for (n, slice) in slices.enumerated() {
            let sliceItems = slice.records.map { items[$0.index] }
            let failed = try await applyHistory(records: sliceItems, progress: progress)
            if failed > 0 {
                // What did land is flushed; the history id stays at the
                // previous slice so this one replays next pass.
                PerfMetrics.measure(.syncHistoryPartial, meta: "failed=\(failed) slice=\(n + 1)/\(slices.count)") { () }
                progress?("Sync incomplete (\(failed) messages pending retry)…")
                throw GmailError.partialFetch(failedCount: failed)
            }
            if n + 1 < slices.count {
                try await commitHistoryId(slice.lastRecordId)
            }
        }
        return latest
    }

    /// Durable progress marker for a partially completed catch-up.
    private func commitHistoryId(_ id: String) async throws {
        try await db.write { [accountId] db in
            try db.execute(sql: "UPDATE account SET historyId = ? WHERE id = ?",
                           arguments: [id, accountId])
        }
    }

    private func commitAccountState(historyId: String? = nil,
                                    lastSyncAt: Date? = nil) async throws {
        try await db.write { [accountId] db in
            if let historyId {
                try db.execute(sql: "UPDATE account SET historyId = ? WHERE id = ?",
                               arguments: [historyId, accountId])
            }
            if let lastSyncAt {
                try db.execute(sql: "UPDATE account SET lastSyncAt = ? WHERE id = ?",
                               arguments: [lastSyncAt, accountId])
            }
        }
    }

    /// Applies one slice of history records: full fetches for added or
    /// uncached messages, in-place label patches for cached ones, deletes.
    /// Returns how many fetches were still failing after retries (those ids
    /// are not in the store; the caller must not advance past them).
    private func applyHistory(records: [GHistoryList.Item],
                              progress: (@Sendable (String) -> Void)?) async throws -> Int {
        // messagesAdded (and label changes for unknown local messages) need a
        // full getMessage; label-only changes on cached messages apply locally.
        var fullFetch = Set<String>()
        var deleted = Set<String>()
        // Ordered per-message label ops so add/remove sequences apply correctly.
        var labelOps: [String: [(add: [String], remove: [String])]] = [:]
        for item in records {
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

        fullFetch.subtract(deleted)
        for id in deleted { labelOps.removeValue(forKey: id) }
        for id in fullFetch { labelOps.removeValue(forKey: id) }

        // Collect the distinct thread keys affected by this batch so each
        // thread is re-derived exactly once, after all message upserts/
        // deletes for the batch are applied (rather than once per message).
        var touchedKeys = Set<String>()

        if !deleted.isEmpty {
            let ids = deleted.map { "\(accountId):\($0)" }
            let keys = try await db.write { db in
                try Self.deleteMessages(db, localIds: ids)
            }
            touchedKeys.formUnion(keys)
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
                    guard let msg = try Message.fetchOne(db, key: key) else {
                        missing.append(gmailId)
                        continue
                    }
                    var labelIds = msg.labelIds
                    for op in ops {
                        labelIds = Self.applyLabelDelta(labelIds: labelIds,
                                                        add: op.add, remove: op.remove)
                    }
                    let isUnread = labelIds.split(separator: " ").contains("UNREAD")
                    try db.execute(
                        sql: "UPDATE message SET labelIds = ?, isUnread = ? WHERE id = ?",
                        arguments: [labelIds, isUnread, msg.id])
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
                try Self.existingMessageIds(
                    db, localIds: fullIds.map { "\(account):\($0)" })
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
                for range in Self.parseSliceRanges(count: report.messages.count) {
                    let slice = Array(report.messages[range])
                    let parsedSlice = await MessageParser.parseConcurrently(
                        slice, accountId: accountId)
                    for (message, attachments) in parsedSlice {
                        writeBuffer.append(PendingUpsert(
                            message: message, attachments: attachments, headersOnly: false))
                        if writeBuffer.count >= Self.writeChunkSize {
                            try await flushUpserts(&writeBuffer, into: &touchedKeys)
                        }
                    }
                }
                if report.hasRetryExhausted {
                    // A quota penalty on full bodies means the metadata pass
                    // would only spend more units and still cannot complete
                    // this slice. Leave all metadata ids pending for replay.
                    retryExhausted += needMeta.count
                    needMeta.removeAll(keepingCapacity: true)
                }
            }
            if !needMeta.isEmpty {
                let report = try await client.getMessages(ids: needMeta, format: "metadata")
                retryExhausted += report.retryExhaustedIds.count
                let parsedPage = await MessageParser.parseConcurrently(
                    report.messages, accountId: accountId)
                for (message, _) in parsedPage {
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
                try await removeOrphanedThreads(for: touchedKeys)
            }
            return retryExhausted
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
            try await removeOrphanedThreads(for: touchedKeys)
        }
        return 0
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

    /// Full-body parse slice. Parallel parse holds every parsed message of
    /// its input at once; 128 keeps several cores busy while bounding peak
    /// memory to a fraction of a 500-message list page.
    static let parseSliceSize = 128

    /// Index ranges, not copies: only the slice being parsed is copied.
    static func parseSliceRanges(count: Int) -> [Range<Int>] {
        stride(from: 0, to: count, by: parseSliceSize).map {
            $0..<min($0 + parseSliceSize, count)
        }
    }

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
            let existing = try Message.fetchOne(db, key: msg.id)
            if item.headersOnly {
                // Preserve body + attachments; keep hasAttachment if metadata
                // reported none (empty payload always looks attachment-free).
                if let existing {
                    if !msg.hasAttachment { msg.hasAttachment = existing.hasAttachment }
                    // A metadata payload that omitted headers must not wipe a
                    // recorded List-Unsubscribe. Empty incoming + recorded
                    // existing → keep. A real parse with no header stores "".
                    if (msg.listUnsubscribe ?? "").isEmpty,
                       let kept = existing.listUnsubscribe, !kept.isEmpty {
                        msg.listUnsubscribe = existing.listUnsubscribe
                        msg.listUnsubscribePost = existing.listUnsubscribePost
                    }
                }
                msg.bodyText = ""
                msg.bodyHTML = nil
                try writeMessageRow(db, msg, existing: existing)
                keys.insert(msg.threadId)
                continue
            }
            // Split body into message_body (v24); keep on-row columns empty so
            // header projections stay cheap under SQLCipher.
            let bodyText = msg.bodyText
            let bodyHTML = msg.bodyHTML
            msg.bodyText = ""
            msg.bodyHTML = nil
            try writeMessageRow(db, msg, existing: existing)
            try MessageBody(messageId: msg.id, bodyText: bodyText, bodyHTML: bodyHTML).save(db)
            try AttachmentRow.filter(Column("messageId") == item.message.id).deleteAll(db)
            for att in item.attachments {
                try att.insert(db)
            }
            keys.insert(item.message.threadId)
        }
        return keys
    }

    /// Insert, or update only the columns that changed.
    ///
    /// A full-row `save` names every column in its UPDATE, so the v40 FTS
    /// trigger (`AFTER UPDATE OF subject, fromHeader, toHeader, ccHeader`)
    /// fired — deleting and re-inserting the message's FTS entry — even for
    /// a label-only change or an identical replay. `updateChanges` writes
    /// only the differing columns (nothing at all when the row is equal), so
    /// the trigger fires only when an indexed header really changed.
    private static func writeMessageRow(_ db: Database, _ msg: Message,
                                        existing: Message?) throws {
        if let existing {
            try msg.updateChanges(db, from: existing)
        } else {
            try msg.insert(db)
        }
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
    ///
    /// Large key sets (a full backfill, a window change, a rebuild) commit
    /// in chunks of `deriveChunkSize` threads so the writer is released
    /// between chunks and user actions (mark read, archive) are not queued
    /// behind one multi-second transaction. Splitting adds no new failure
    /// state: the message rows these keys cover were already committed by
    /// earlier `flushUpserts` transactions, so a crash between two derive
    /// chunks leaves the same "messages written, thread not yet derived"
    /// state a crash between flush and derive always could. historyId is
    /// committed only after this returns, as before.
    private func deriveThreads(for keys: Set<String>) async throws {
        guard !keys.isEmpty else { return }
        for chunk in Self.deriveChunks(keys) {
            let chunkKeys = Set(chunk)
            try await db.write { [accountId] db in
                try Self.deriveThreads(db, for: chunkKeys, accountId: accountId)
            }
            // Single choke point for message-row writes: everything that
            // rewrites messages re-derives their threads here, so recording
            // the keys once covers backfill, history catch-up, window changes
            // and search. Per chunk, so a later chunk's failure still reports
            // the threads that did change.
            touchedThreadIds.formUnion(chunkKeys)
        }
    }

    /// Threads re-derived per write transaction in `deriveThreads(for:)`.
    static let deriveChunkSize = 500

    /// Splits thread keys into runs of at most `deriveChunkSize`. Sorted so
    /// the chunking is deterministic (Set order is not).
    static func deriveChunks(_ keys: Set<String>) -> [ArraySlice<String>] {
        let sorted = keys.sorted()
        return stride(from: 0, to: sorted.count, by: deriveChunkSize).map {
            sorted[$0..<min($0 + deriveChunkSize, sorted.count)]
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
            // Most touched threads come out identical (a label-only change on
            // an old message, a replayed history record). Skipping the no-op
            // UPDATE saves a page rewrite (and its SQLCipher encrypt + HMAC)
            // plus the index updates on every thread column.
            if thread != existing {
                try thread.save(db)
            }
            // Still reconciled when the row is unchanged: it is a read-only
            // no-op when the junction already matches, and this pass is what
            // heals a junction that drifted from labelIds.
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
    private func removeOrphanedThreads(for keys: Set<String>? = nil) async throws {
        try await db.write { [accountId] db in
            if let keys {
                try Self.removeOrphanedThreads(db, accountId: accountId, keys: keys)
            } else {
                try db.execute(sql: """
                    DELETE FROM thread WHERE accountId = ?
                    AND id NOT IN (SELECT DISTINCT threadId FROM message WHERE accountId = ?)
                    """, arguments: [accountId, accountId])
            }
        }
    }
}
