import XCTest
import GRDB

/// Regression tests for the "trash during committed search" flicker: with a
/// `/` search active, trashing a thread optimistically removed the row, but
/// the async `reloadThreads()` search SQL had no trash/spam exclusion, so the
/// row bounced back. The fix has two halves that must agree:
///
///   1. Optimistic: `threadLeavesCurrentList` uses
///      `SearchQuery.includesLocation` when a committed search is active.
///   2. Reload: the search branch of `MailStore.reloadThreads` filters the
///      SQL by `parsed.location` (standard excludes inTrash/inSpam).
///
/// MailStore itself is AppKit-bound and not compiled into this test target,
/// so `searchReload` below runs the production search query
/// (`SearchThreadQuery`, which `MailStore.reloadThreads` calls) against a
/// real migrated in-memory DB.
final class SearchTrashFlickerTests: XCTestCase {

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
                            labelIds: String = "INBOX") -> MailThread {
        var t = MailThread(
            id: "a:\(id)", accountId: "a@x.com", gmailThreadId: id,
            subject: subject, snippet: "sn", fromDisplay: "F",
            lastDate: Date(), isUnread: false, isStarred: false,
            inInbox: false, inTrash: false,
            labelIds: labelIds, snoozeUntil: nil, participants: "F",
            messageCount: 1, hasAttachment: false, reminderAt: nil)
        t.syncFlagsFromLabelIds()
        return t
    }

    /// Insert a thread plus one message so message_fts (subject + fromHeader,
    /// synchronized by triggers) can serve the full-text search path.
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

    /// The committed-search branch of `MailStore.reloadThreads` (production
    /// builder: FTS text match plus the `parsed.location` scope filter).
    private func searchReload(_ db: Database, _ raw: String) throws -> [MailThread] {
        try SearchThreadQuery.fetch(search: raw, db: db, context: .init(), limit: 200)
    }

    /// Mirrors the committed-search branch of `threadLeavesCurrentList`.
    private func leavesSearchList(_ t: MailThread, search: String) -> Bool {
        !SearchQuery.parse(search).includesLocation(inTrash: t.inTrash, inSpam: t.inSpam)
    }

    // MARK: - Trash during committed search

    func testTrashDuringSearchStaysGoneAfterReload() throws {
        let q = try makeDB()
        var invoice = makeThread(id: "t1", subject: "Invoice from Acme")
        let other = makeThread(id: "t2", subject: "Invoice reminder")
        try q.write { db in
            try self.seed(db, invoice)
            try self.seed(db, other)
        }

        // Both match the committed search before the trash.
        try q.read { db in
            XCTAssertEqual(try self.searchReload(db, "invoice").map(\.id).sorted(),
                           ["a:t1", "a:t2"])
        }

        // Optimistic trash: same mutation `MailStore.trash` applies.
        invoice.applyLabelMutation(add: ["TRASH"], remove: ["INBOX"])
        XCTAssertTrue(invoice.inTrash)
        // The optimistic path removes the row immediately...
        XCTAssertTrue(leavesSearchList(invoice, search: "invoice"))

        // ...and after the write lands, the async reload must NOT bring it
        // back (this was the flicker).
        try q.write { db in try invoice.update(db) }
        try q.read { db in
            XCTAssertEqual(try self.searchReload(db, "invoice").map(\.id), ["a:t2"])
        }
    }

    func testInTrashSearchIncludesTrashedThread() throws {
        let q = try makeDB()
        var invoice = makeThread(id: "t1", subject: "Invoice from Acme")
        invoice.applyLabelMutation(add: ["TRASH"], remove: ["INBOX"])
        let other = makeThread(id: "t2", subject: "Invoice reminder")
        try q.write { db in
            try self.seed(db, invoice)
            try self.seed(db, other)
        }

        try q.read { db in
            XCTAssertEqual(try self.searchReload(db, "invoice in:trash").map(\.id),
                           ["a:t1"])
            // in:anywhere sees both sides.
            XCTAssertEqual(try self.searchReload(db, "invoice in:anywhere").map(\.id).sorted(),
                           ["a:t1", "a:t2"])
        }
        // Optimistic side agrees: a trashed thread stays in an in:trash list.
        XCTAssertFalse(leavesSearchList(invoice, search: "invoice in:trash"))
        XCTAssertFalse(leavesSearchList(invoice, search: "invoice in:anywhere"))
        // And undoing the trash from an in:trash search removes it there.
        invoice.applyLabelMutation(add: ["INBOX"], remove: ["TRASH"])
        XCTAssertTrue(leavesSearchList(invoice, search: "invoice in:trash"))
    }

    func testArchiveDuringSearchKeepsRow() throws {
        let q = try makeDB()
        var invoice = makeThread(id: "t1", subject: "Invoice from Acme")
        try q.write { db in try self.seed(db, invoice) }

        // Archive: out of inbox, not trash/spam — search still includes it.
        invoice.applyLabelMutation(remove: ["INBOX"])
        XCTAssertFalse(invoice.inTrash)
        XCTAssertFalse(invoice.inSpam)
        XCTAssertFalse(invoice.inInbox)
        XCTAssertFalse(leavesSearchList(invoice, search: "invoice"))

        try q.write { db in try invoice.update(db) }
        try q.read { db in
            XCTAssertEqual(try self.searchReload(db, "invoice").map(\.id), ["a:t1"])
        }
    }

    func testSpamExcludedFromStandardSearchIncludedByInSpam() throws {
        let q = try makeDB()
        var invoice = makeThread(id: "t1", subject: "Invoice from Acme")
        invoice.applyLabelMutation(add: ["SPAM"], remove: ["INBOX"])
        try q.write { db in try self.seed(db, invoice) }

        XCTAssertTrue(leavesSearchList(invoice, search: "invoice"))
        XCTAssertFalse(leavesSearchList(invoice, search: "invoice in:spam"))
        try q.read { db in
            XCTAssertTrue(try self.searchReload(db, "invoice").isEmpty)
            XCTAssertEqual(try self.searchReload(db, "invoice in:spam").map(\.id),
                           ["a:t1"])
        }
    }
}
