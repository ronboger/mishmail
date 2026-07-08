import XCTest
import GRDB

final class DatabaseMigrationTests: XCTestCase {

    /// A fresh (in-memory) database migrates cleanly through every version.
    func testFreshDatabaseMigrates() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.read { db in
            for table in ["account", "thread", "message", "label", "snippet",
                          "attachment", "savedView", "scheduledSend"] {
                XCTAssertTrue(try db.tableExists(table), "missing table \(table)")
            }
            XCTAssertTrue(try db.tableExists("message_fts"))
            XCTAssertTrue(try db.tableExists("vipSender"), "v11 must add vipSender")
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

    /// A label created before v10 survives the upgrade and gains the color
    /// (nil) and sortOrder (unsorted) columns with their defaults; new values
    /// round-trip through LabelRow.
    func testUpgradeFromV9AddsLabelColorAndOrder() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v9")
        try q.write { db in
            try db.execute(sql: "INSERT INTO account (id, displayName, senderName) VALUES ('ron@x.com', 'Personal', '')")
            try db.execute(sql: """
                INSERT INTO label (id, accountId, gmailLabelId, name, type)
                VALUES ('ron@x.com:Label_1', 'ron@x.com', 'Label_1', 'Work', 'user')
                """)
        }
        try AppDatabase.migrator.migrate(q)
        let cols = try q.read { try $0.columns(in: "label").map(\.name) }
        XCTAssertTrue(cols.contains("color"), "v10 must add color")
        XCTAssertTrue(cols.contains("sortOrder"), "v10 must add sortOrder")

        var label = try XCTUnwrap(try q.read { try LabelRow.fetchOne($0, key: "ron@x.com:Label_1") })
        XCTAssertNil(label.color)
        XCTAssertEqual(label.sortOrder, LabelRow.unsorted)

        label.color = "#EB5757"
        label.sortOrder = 0
        try q.write { db in try label.save(db) }
        let reloaded = try q.read { try LabelRow.fetchOne($0, key: "ron@x.com:Label_1") }
        XCTAssertEqual(reloaded?.color, "#EB5757")
        XCTAssertEqual(reloaded?.sortOrder, 0)
    }

    /// A database created before v5 (real upgrade path) gains the
    /// scheduledSend table without touching existing rows.
    func testUpgradeFromV4AddsScheduledSends() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v4")
        try q.write { db in
            try db.execute(sql: "INSERT INTO account (id, displayName, senderName) VALUES ('ron@x.com', 'Personal', '')")
            XCTAssertFalse(try db.tableExists("scheduledSend"))
        }
        try AppDatabase.migrator.migrate(q)
        try q.read { db in
            XCTAssertTrue(try db.tableExists("scheduledSend"))
            XCTAssertEqual(try Account.fetchCount(db), 1)
        }
    }

    /// Scheduled sends round-trip, including their JSON-packed attachments.
    func testScheduledSendRoundTrip() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        let attachments = [MIMEBuilder.Attachment(filename: "a.pdf", mimeType: "application/pdf",
                                                  data: Data([1, 2, 3]))]
        let row = ScheduledSend(
            id: nil, accountId: "ron@x.com", toHeader: "jane@y.com",
            ccHeader: "", bccHeader: "", subject: "Later", body: "see you monday",
            sendAt: Date(timeIntervalSince1970: 1_800_000_000),
            replyToMessageId: nil, forward: false, replacingDraftId: "ron@x.com:d1",
            attachmentsJSON: ScheduledSend.encodeAttachments(attachments),
            createdAt: Date(timeIntervalSince1970: 1_751_500_000))
        try q.write { db in try row.insert(db) }

        let fetched = try q.read { db in try ScheduledSend.fetchOne(db) }
        XCTAssertNotNil(fetched?.id)
        XCTAssertEqual(fetched?.subject, "Later")
        XCTAssertEqual(fetched?.replacingDraftId, "ron@x.com:d1")
        XCTAssertEqual(fetched?.attachments.count, 1)
        XCTAssertEqual(fetched?.attachments.first?.filename, "a.pdf")
        XCTAssertEqual(fetched?.attachments.first?.data, Data([1, 2, 3]))
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

    /// v15 rebuilds message_fts with prefix indexes. A message indexed before
    /// the upgrade must survive: the rebuilt index repopulates from it (so
    /// pre-v15 mail is still searchable), prefix queries match, and the sync
    /// triggers keep working after the rebuild.
    func testUpgradeToV15AddsFTSPrefixIndexes() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v14")
        try q.write { db in
            try db.execute(sql: "INSERT INTO account (id, displayName, senderName) VALUES ('ron@x.com', 'P', '')")
            try db.execute(sql: """
                INSERT INTO message (id, accountId, gmailId, threadId, fromHeader, toHeader,
                    ccHeader, bccHeader, subject, date, snippet, bodyText, messageIdHeader,
                    referencesHeader, labelIds, isUnread, hasAttachment)
                VALUES ('ron@x.com:m1', 'ron@x.com', 'm1', 'ron@x.com:t1', 'jane@y.com', '',
                    '', '', 'Zebra migration plans', '2026-01-01 00:00:00', '', 'the quick brown fox',
                    '<id@mail>', '', 'INBOX', 1, 0)
                """)
        }
        try AppDatabase.migrator.migrate(q)   // through v15

        // The rebuilt FTS table declares prefix indexes.
        let sql = try q.read { db in
            try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'message_fts'") ?? ""
        }
        XCTAssertTrue(sql.lowercased().contains("prefix"),
                      "v15 must declare FTS prefix indexes; got: \(sql)")

        try q.read { db in
            // The pre-v15 row was repopulated into the rebuilt index …
            let full = try Int.fetchOne(db, sql:
                "SELECT count(*) FROM message_fts WHERE message_fts MATCH 'zebra'") ?? 0
            XCTAssertEqual(full, 1, "existing rows must repopulate the rebuilt index")
            // … and a prefix query matches it.
            let prefix = try Int.fetchOne(db, sql:
                "SELECT count(*) FROM message_fts WHERE message_fts MATCH 'mig*'") ?? 0
            XCTAssertEqual(prefix, 1, "prefix query must match")
        }

        // The sync triggers survive the rebuild: deleting the row clears it.
        _ = try q.write { db in try Message.deleteOne(db, key: "ron@x.com:m1") }
        let after = try q.read { db in
            try Int.fetchOne(db, sql:
                "SELECT count(*) FROM message_fts WHERE message_fts MATCH 'zebra'") ?? 0
        }
        XCTAssertEqual(after, 0, "sync triggers must survive the FTS rebuild")
    }
}
