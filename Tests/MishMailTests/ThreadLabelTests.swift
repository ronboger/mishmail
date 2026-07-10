import XCTest
import GRDB

final class ThreadLabelTests: XCTestCase {
    private let account = "a@x.com"

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: account, displayName: "A", historyId: nil,
                        lastSyncAt: nil, senderName: "").insert(db)
        }
        return q
    }

    private func seedMessage(_ db: Database, gmailId: String, labels: String,
                             from: String = "Alice <alice@x.com>") throws {
        let threadId = "\(account):\(gmailId)"
        try Message(
            id: "\(threadId):m", accountId: account, gmailId: "\(gmailId)m",
            threadId: threadId, fromHeader: from, toHeader: "me@x.com",
            ccHeader: "", subject: "s", date: Date(), snippet: "sn",
            bodyText: "body", bodyHTML: nil, messageIdHeader: "<x>",
            referencesHeader: "", labelIds: labels, isUnread: true,
            hasAttachment: false).insert(db)
    }

    func testDeriveRewritesUserLabelsOnly() throws {
        let q = try makeDB()
        try q.write { db in
            try self.seedMessage(db, gmailId: "t1",
                                 labels: "INBOX UNREAD Label_42 Label_99")
            try SyncEngine.deriveThreads(db, for: ["\(account):t1"], accountId: account)
        }
        let labs = try q.read {
            try ThreadLabel.filter(Column("threadId") == "\(account):t1")
                .order(Column("labelId")).fetchAll($0)
        }
        XCTAssertEqual(labs.map(\.labelId), ["Label_42", "Label_99"])
        let thread = try q.read { try MailThread.fetchOne($0, key: "\(account):t1") }
        XCTAssertTrue(thread?.allFromEmails.contains("alice@x.com") == true)
    }

    func testRewriteRemovesStaleLabels() throws {
        let q = try makeDB()
        try q.write { db in
            try self.seedMessage(db, gmailId: "t1", labels: "INBOX Label_1")
            try SyncEngine.deriveThreads(db, for: ["\(account):t1"], accountId: account)
            try ThreadLabels.rewrite(db, threadId: "\(account):t1",
                                     labelIds: "INBOX Label_2")
        }
        let labs = try q.read {
            try String.fetchAll($0, sql:
                "SELECT labelId FROM thread_label WHERE threadId = ?",
                arguments: ["\(account):t1"])
        }
        XCTAssertEqual(labs, ["Label_2"])
    }

    func testJunctionQueryNoPartialTokenMatch() throws {
        let q = try makeDB()
        try q.write { db in
            try self.seedMessage(db, gmailId: "t1", labels: "INBOX Label_12")
            try self.seedMessage(db, gmailId: "t2", labels: "INBOX Label_1")
            try SyncEngine.deriveThreads(db, for: ["\(account):t1", "\(account):t2"],
                                         accountId: account)
        }
        // LIKE '%Label_1%' would false-match Label_12; junction must not.
        let hits = try q.read { db in
            try String.fetchAll(db, sql: """
                SELECT thread.id FROM thread
                WHERE EXISTS (
                    SELECT 1 FROM thread_label
                    WHERE threadId = thread.id AND labelId = ?)
                ORDER BY thread.id
                """, arguments: ["Label_1"])
        }
        XCTAssertEqual(hits, ["\(account):t2"])
    }

    func testBlocklistMatchesAnyFromViaAllFromEmails() {
        XCTAssertTrue(ThreadLabels.matchesBlocklist(
            fromEmail: "newest@x.com",
            allFromEmails: "old@x.com newest@x.com",
            blocked: ["old@x.com"]))
        XCTAssertFalse(ThreadLabels.matchesBlocklist(
            fromEmail: "ok@x.com",
            allFromEmails: "ok@x.com",
            blocked: ["bad@x.com"]))
    }

    /// Shipping SQL uses instr() token match — underscore must not be LIKE wild.
    func testBlocklistSQLDoesNotWildcardUnderscore() throws {
        let q = try makeDB()
        try q.write { db in
            try self.seedMessage(db, gmailId: "t1", labels: "INBOX",
                                 from: "John <john_doe@x.com>")
            try self.seedMessage(db, gmailId: "t2", labels: "INBOX",
                                 from: "Jane <johnadoe@x.com>")
            try SyncEngine.deriveThreads(
                db, for: ["\(account):t1", "\(account):t2"], accountId: account)
        }
        let hits = try q.read { db in
            try String.fetchAll(db, sql: """
                SELECT id FROM thread
                WHERE inInbox = 1 AND inTrash = 0
                  AND (fromEmail = ?
                       OR instr(' ' || allFromEmails || ' ', ' ' || ? || ' ') > 0)
                ORDER BY id
                """, arguments: ["john_doe@x.com", "john_doe@x.com"])
        }
        XCTAssertEqual(hits, ["\(account):t1"],
                       "john_doe must not match johnadoe via LIKE _")
    }

    func testMigrationCreatesThreadLabel() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.read { db in
            XCTAssertTrue(try db.tableExists("thread_label"))
            let cols = try db.columns(in: "thread").map(\.name)
            XCTAssertTrue(cols.contains("allFromEmails"))
        }
    }
}
