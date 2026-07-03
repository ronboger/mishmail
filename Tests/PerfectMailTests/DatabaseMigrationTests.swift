import XCTest
import GRDB

final class DatabaseMigrationTests: XCTestCase {

    /// A fresh (in-memory) database migrates cleanly through every version.
    func testFreshDatabaseMigrates() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.read { db in
            for table in ["account", "thread", "message", "label", "snippet",
                          "attachment", "savedView"] {
                XCTAssertTrue(try db.tableExists(table), "missing table \(table)")
            }
            XCTAssertTrue(try db.tableExists("message_fts"))
            let messageCols = try db.columns(in: "message").map(\.name)
            XCTAssertTrue(messageCols.contains("bccHeader"), "v4 must add bccHeader")
            XCTAssertTrue(messageCols.contains("hasAttachment"))
            let accountCols = try db.columns(in: "account").map(\.name)
            XCTAssertTrue(accountCols.contains("senderName"), "v3 must add senderName")
        }
    }

    /// A database created before v4 (real upgrade path) keeps its rows and
    /// gains the new column with its default.
    func testUpgradeFromV3PreservesMessages() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v3")
        try q.write { db in
            try db.execute(sql: "INSERT INTO account (id, displayName, senderName) VALUES ('ron@x.com', 'Personal', '')")
            try db.execute(sql: """
                INSERT INTO message (id, accountId, gmailId, threadId, fromHeader, toHeader,
                    ccHeader, subject, date, snippet, bodyText, messageIdHeader,
                    referencesHeader, labelIds, isUnread, hasAttachment)
                VALUES ('ron@x.com:m1', 'ron@x.com', 'm1', 'ron@x.com:t1', 'a@b.com', 'ron@x.com',
                    '', 'Old mail', '2026-01-01 00:00:00', 's', 'body', '<id@mail>',
                    '', 'INBOX', 1, 0)
                """)
        }
        try AppDatabase.migrator.migrate(q)
        let message = try q.read { db in try Message.fetchOne(db, key: "ron@x.com:m1") }
        XCTAssertNotNil(message)
        XCTAssertEqual(message?.bccHeader, "")
        XCTAssertEqual(message?.subject, "Old mail")
    }

    /// Records round-trip through the schema (catches record/column drift).
    func testRecordRoundTrip() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)

        let account = Account(id: "ron@x.com", displayName: "Personal",
                              historyId: "123", lastSyncAt: Date(), senderName: "Ron Boger")
        let message = Message(
            id: "ron@x.com:m1", accountId: "ron@x.com", gmailId: "m1",
            threadId: "ron@x.com:t1", fromHeader: "Jane <jane@y.com>",
            toHeader: "ron@x.com", ccHeader: "cc@y.com", bccHeader: "bcc@z.com",
            subject: "Subject", date: Date(timeIntervalSince1970: 1_751_500_000),
            snippet: "snip", bodyText: "body text", bodyHTML: "<p>html</p>",
            messageIdHeader: "<id@mail>", referencesHeader: "<ref@mail>",
            labelIds: "INBOX UNREAD", isUnread: true, hasAttachment: false)

        try q.write { db in
            try account.save(db)
            try message.save(db)
        }
        let fetched = try q.read { db in try Message.fetchOne(db, key: "ron@x.com:m1") }
        XCTAssertEqual(fetched, message)
    }

    /// The FTS index is kept in sync by triggers and finds message bodies.
    func testFullTextSearchStaysInSync() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: "ron@x.com", displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            try Message(
                id: "ron@x.com:m1", accountId: "ron@x.com", gmailId: "m1",
                threadId: "ron@x.com:t1", fromHeader: "jane@y.com", toHeader: "",
                ccHeader: "", bccHeader: "", subject: "Zebra migration plans",
                date: Date(), snippet: "", bodyText: "the quick brown fox",
                bodyHTML: nil, messageIdHeader: "", referencesHeader: "",
                labelIds: "", isUnread: false, hasAttachment: false).save(db)
        }
        let hits = try q.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM message_fts WHERE message_fts MATCH 'zebra'") ?? 0
        }
        XCTAssertEqual(hits, 1)

        // Deleting the row removes it from the index.
        _ = try q.write { db in try Message.deleteOne(db, key: "ron@x.com:m1") }
        let after = try q.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM message_fts WHERE message_fts MATCH 'zebra'") ?? 0
        }
        XCTAssertEqual(after, 0)
    }

    /// Deleting an account cascades to its threads, messages and attachments.
    func testAccountDeleteCascades() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: "ron@x.com", displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            try Message(
                id: "ron@x.com:m1", accountId: "ron@x.com", gmailId: "m1",
                threadId: "ron@x.com:t1", fromHeader: "", toHeader: "",
                ccHeader: "", bccHeader: "", subject: "", date: Date(),
                snippet: "", bodyText: "", bodyHTML: nil, messageIdHeader: "",
                referencesHeader: "", labelIds: "", isUnread: false,
                hasAttachment: true).save(db)
            var att = AttachmentRow(id: nil, messageId: "ron@x.com:m1",
                                    gmailAttachmentId: "a1", filename: "f.pdf",
                                    mimeType: "application/pdf", size: 1)
            try att.insert(db)
            _ = try Account.deleteOne(db, key: "ron@x.com")
        }
        try q.read { db in
            XCTAssertEqual(try Message.fetchCount(db), 0)
            XCTAssertEqual(try AttachmentRow.fetchCount(db), 0)
        }
    }
}
