import XCTest
import GRDB

/// Regression: opening a thread under a committed `is:unread` (or `is:read`)
/// search auto-marks it read, which used to drop the row from the list
/// immediately — selection and reading-pane vanished under the cursor.
///
/// Chip / saved-view unread filters already pin via `readStateKeepIds`. Search
/// must use the same keep-ids OR on the isUnread filter so a just-toggled
/// thread stays listed until the search is cleared or the view changes.
///
/// MailStore is AppKit-bound and not in this test target, so
/// `searchReload` mirrors the production search branch (including keepIds).
/// Update this copy if `MailStore.reloadThreads` search SQL changes.
final class SearchUnreadStickinessTests: XCTestCase {

    // MARK: - Fixtures

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: "a@x.com", displayName: "A", historyId: nil,
                        lastSyncAt: nil, senderName: "").insert(db)
        }
        return q
    }

    private func makeThread(id: String, subject: String,
                            isUnread: Bool,
                            labelIds: String = "INBOX UNREAD") -> MailThread {
        var t = MailThread(
            id: "a:\(id)", accountId: "a@x.com", gmailThreadId: id,
            subject: subject, snippet: "sn", fromDisplay: "F",
            lastDate: Date(), isUnread: isUnread, isStarred: false,
            inInbox: true, inTrash: false,
            labelIds: labelIds, snoozeUntil: nil, participants: "F",
            messageCount: 1, hasAttachment: false, reminderAt: nil)
        t.syncFlagsFromLabelIds()
        // syncFlagsFromLabelIds may overwrite isUnread from labels — force the
        // intended state for the test scenario.
        t.isUnread = isUnread
        if isUnread {
            if !t.labelIds.split(separator: " ").map(String.init).contains("UNREAD") {
                t.labelIds = (t.labelIds + " UNREAD").trimmingCharacters(in: .whitespaces)
            }
        } else {
            t.labelIds = t.labelIds
                .split(separator: " ")
                .map(String.init)
                .filter { $0 != "UNREAD" }
                .joined(separator: " ")
        }
        return t
    }

    private func seed(_ db: Database, _ t: MailThread) throws {
        try t.insert(db)
        try Message(
            id: "\(t.id):m1", accountId: t.accountId, gmailId: "\(t.gmailThreadId)m1",
            threadId: t.id, fromHeader: "F <f@x.com>", toHeader: "me@x.com",
            ccHeader: "", subject: t.subject, date: t.lastDate,
            snippet: t.snippet, bodyText: "body", bodyHTML: nil,
            messageIdHeader: "<\(t.id)@x>", referencesHeader: "",
            labelIds: t.labelIds, isUnread: t.isUnread,
            hasAttachment: t.hasAttachment).insert(db)
    }

    /// Mirrors the committed-search branch of `MailStore.reloadThreads` for
    /// is:unread / is:read, including keepIds stickiness.
    private func searchReload(_ db: Database, _ raw: String,
                              keepIds: [String] = []) throws -> [MailThread] {
        let parsed = SearchQuery.parse(raw)
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
        if let unread = parsed.unread {
            q = q.filter(Column("isUnread") == unread
                         || keepIds.contains(Column("id")))
        }
        switch parsed.location {
        case .standard:
            q = q.filter(Column("inTrash") == false && Column("inSpam") == false)
        case .trash:
            q = q.filter(Column("inTrash") == true)
        case .spam:
            q = q.filter(Column("inSpam") == true)
        case .anywhere:
            break
        }
        return try q.order(Column("lastDate").desc).limit(200).fetchAll(db)
    }

    /// Whether a committed search's read-state operator is active (same gate
    /// `MailStore.readStateFilterActive` uses for the search half).
    private func searchReadStateFilterActive(_ raw: String) -> Bool {
        let search = raw.trimmingCharacters(in: .whitespaces)
        guard !search.isEmpty else { return false }
        return SearchQuery.parse(search).unread != nil
    }

    // MARK: - Gate

    func testIsUnreadSearchActivatesReadStateFilter() {
        XCTAssertTrue(searchReadStateFilterActive("is:unread"))
        XCTAssertTrue(searchReadStateFilterActive("is:read"))
        XCTAssertTrue(searchReadStateFilterActive("from:alice is:unread"))
        XCTAssertFalse(searchReadStateFilterActive("invoice"))
        XCTAssertFalse(searchReadStateFilterActive("is:starred"))
        XCTAssertFalse(searchReadStateFilterActive(""))
    }

    // MARK: - Stickiness

    func testMarkReadUnderIsUnreadSearchKeepsRowWithKeepIds() throws {
        let q = try makeDB()
        var open = makeThread(id: "t1", subject: "Open me", isUnread: true)
        let other = makeThread(id: "t2", subject: "Stay unread", isUnread: true)
        try q.write { db in
            try self.seed(db, open)
            try self.seed(db, other)
        }

        try q.read { db in
            XCTAssertEqual(
                try self.searchReload(db, "is:unread").map(\.id).sorted(),
                ["a:t1", "a:t2"])
        }

        // Auto-mark-read on open (ThreadDetailView → setRead).
        open.isUnread = false
        open.labelIds = open.labelIds
            .split(separator: " ").map(String.init)
            .filter { $0 != "UNREAD" }.joined(separator: " ")
        try q.write { db in try open.update(db) }

        // Without keepIds the opened thread vanishes (the bug).
        try q.read { db in
            XCTAssertEqual(
                try self.searchReload(db, "is:unread").map(\.id),
                ["a:t2"])
        }

        // With keepIds (what setRead inserts when the filter is active) it
        // stays listed so the reading pane doesn't go blank.
        try q.read { db in
            XCTAssertEqual(
                try self.searchReload(db, "is:unread", keepIds: [open.id])
                    .map(\.id).sorted(),
                ["a:t1", "a:t2"])
        }
    }

    func testMarkUnreadUnderIsReadSearchKeepsRowWithKeepIds() throws {
        let q = try makeDB()
        var flipped = makeThread(id: "t1", subject: "Was read", isUnread: false,
                                 labelIds: "INBOX")
        let stays = makeThread(id: "t2", subject: "Still read", isUnread: false,
                               labelIds: "INBOX")
        try q.write { db in
            try self.seed(db, flipped)
            try self.seed(db, stays)
        }

        try q.read { db in
            XCTAssertEqual(
                try self.searchReload(db, "is:read").map(\.id).sorted(),
                ["a:t1", "a:t2"])
        }

        flipped.isUnread = true
        flipped.labelIds = (flipped.labelIds + " UNREAD")
            .trimmingCharacters(in: .whitespaces)
        try q.write { db in try flipped.update(db) }

        try q.read { db in
            XCTAssertEqual(
                try self.searchReload(db, "is:read").map(\.id),
                ["a:t2"])
            XCTAssertEqual(
                try self.searchReload(db, "is:read", keepIds: [flipped.id])
                    .map(\.id).sorted(),
                ["a:t1", "a:t2"])
        }
    }

    func testKeepIdsDoNotLeakIntoUnrelatedSearch() throws {
        // keepIds only widen the isUnread filter; a free-text search that
        // doesn't match must still exclude the row.
        let q = try makeDB()
        var open = makeThread(id: "t1", subject: "Invoice Acme", isUnread: true)
        try q.write { db in try self.seed(db, open) }

        open.isUnread = false
        try q.write { db in try open.update(db) }

        try q.read { db in
            // is:unread + keepIds: still listed.
            XCTAssertEqual(
                try self.searchReload(db, "is:unread", keepIds: [open.id]).map(\.id),
                ["a:t1"])
            // Different free-text query: keepIds alone must not resurrect it
            // (no is:unread clause to OR against).
            XCTAssertEqual(
                try self.searchReload(db, "unicorn-zzzz", keepIds: [open.id]).map(\.id),
                [])
        }
    }

    func testKeepIdsOnlyBypassUnreadNotOtherOperators() throws {
        // Stickiness must not defeat from:/text/etc. — only the read-state
        // clause. Mirrors: keepIds OR is applied solely on isUnread.
        let q = try makeDB()
        var sticky = makeThread(id: "t1", subject: "Invoice Acme", isUnread: true)
        let other = makeThread(id: "t2", subject: "Invoice Other", isUnread: true)
        try q.write { db in
            try self.seed(db, sticky)
            try self.seed(db, other)
        }

        sticky.isUnread = false
        try q.write { db in try sticky.update(db) }

        try q.read { db in
            // Pure is:unread keeps sticky via keepIds.
            XCTAssertEqual(
                try self.searchReload(db, "is:unread", keepIds: [sticky.id])
                    .map(\.id).sorted(),
                ["a:t1", "a:t2"])
            // Combined free-text: sticky no longer matches "Other", keepIds
            // must not pull it back.
            XCTAssertEqual(
                try self.searchReload(db, "is:unread Other", keepIds: [sticky.id])
                    .map(\.id),
                ["a:t2"])
        }
    }

    func testLeavingReadStateFilterDropsStickiness() {
        // Production: reloadThreads clears keepIds when
        // !readStateFilterActive. Search half of that gate must flip off
        // when the operator is gone (clear / re-query without is:unread).
        XCTAssertTrue(searchReadStateFilterActive("is:unread"))
        XCTAssertFalse(searchReadStateFilterActive(""))
        XCTAssertFalse(searchReadStateFilterActive("invoice"))
        // Still-active operator (chip parity): keepIds may persist across
        // re-queries that remain is:unread.
        XCTAssertTrue(searchReadStateFilterActive("is:unread from:alice"))
    }
}
