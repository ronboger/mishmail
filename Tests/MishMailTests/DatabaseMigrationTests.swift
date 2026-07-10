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
            let threadCols = try db.columns(in: "thread").map(\.name)
            for name in ["inSent", "inDrafts", "inPromotions", "inSocial", "fromEmail"] {
                XCTAssertTrue(threadCols.contains(name), "v16 must add \(name)")
            }
            XCTAssertTrue(threadCols.contains("inSpam"), "v19 must add inSpam")
            let ftsSQL = try String.fetchOne(db, sql:
                "SELECT sql FROM sqlite_master WHERE name = 'message_fts'") ?? ""
            XCTAssertFalse(ftsSQL.lowercased().contains("bodytext"),
                           "v17 FTS must omit bodyText")
            // v18 composite indexes for hot list queries (flag + inTrash + lastDate).
            for name in [
                "thread_on_inInbox_inTrash_lastDate",
                "thread_on_inDrafts_inTrash_lastDate",
                "thread_on_inSent_inTrash_lastDate",
                "thread_on_inPromotions_inTrash_lastDate",
                "thread_on_inSocial_inTrash_lastDate",
                "thread_on_isStarred_inTrash_lastDate",
                "thread_on_accountId_lastDate",
            ] {
                let exists = try Bool.fetchOne(db, sql:
                    "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
                    arguments: [name]) ?? false
                XCTAssertTrue(exists, "v18 must create index \(name)")
            }
            let scheduledCols = try db.columns(in: "scheduledSend").map(\.name)
            XCTAssertTrue(scheduledCols.contains("fromEmail"),
                          "v20 must add fromEmail on scheduledSend")
            // v21 partial indexes for SidebarCounts COUNT(*) paths.
            for name in [
                "thread_unread_primary_inbox",
                "thread_unread_promotions",
                "thread_unread_social",
                "thread_starred_active",
                "thread_drafts_active",
            ] {
                let exists = try Bool.fetchOne(db, sql:
                    "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
                    arguments: [name]) ?? false
                XCTAssertTrue(exists, "v21 must create index \(name)")
            }
            // v22: reminders + snoozed (were full scans after v21).
            for name in ["thread_has_reminder", "thread_snoozed_active"] {
                let exists = try Bool.fetchOne(db, sql:
                    "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
                    arguments: [name]) ?? false
                XCTAssertTrue(exists, "v22 must create index \(name)")
            }
            XCTAssertTrue(try db.tableExists("thread_label"), "v23")
            XCTAssertTrue(try db.tableExists("message_body"), "v24")
            let threadColsV23 = try db.columns(in: "thread").map(\.name)
            XCTAssertTrue(threadColsV23.contains("allFromEmails"), "v23")
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
        try AppDatabase.migrator.migrate(q, upTo: "v15")

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

    /// v16 adds denormalized label flags + fromEmail on thread, backfilled
    /// from existing labelIds / newest message From.
    func testUpgradeToV16AddsLabelDenormColumns() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v15")
        try q.write { db in
            try db.execute(sql: "INSERT INTO account (id, displayName, senderName) VALUES ('ron@x.com', 'P', '')")
            try db.execute(sql: """
                INSERT INTO thread (id, accountId, gmailThreadId, subject, snippet, fromDisplay,
                    lastDate, isUnread, isStarred, inInbox, inTrash, labelIds, participants,
                    messageCount, hasAttachment)
                VALUES
                ('ron@x.com:t1', 'ron@x.com', 't1', 's', 'sn', 'Jane',
                 '2026-01-02 00:00:00', 0, 0, 1, 0, 'INBOX SENT CATEGORY_PROMOTIONS', 'Jane', 1, 0),
                ('ron@x.com:t2', 'ron@x.com', 't2', 'd', 'sn', 'Me',
                 '2026-01-02 00:00:00', 0, 0, 0, 0, 'DRAFT CATEGORY_SOCIAL', 'me', 1, 0)
                """)
            try db.execute(sql: """
                INSERT INTO message (id, accountId, gmailId, threadId, fromHeader, toHeader,
                    ccHeader, bccHeader, subject, date, snippet, bodyText, messageIdHeader,
                    referencesHeader, labelIds, isUnread, hasAttachment)
                VALUES
                ('ron@x.com:m1', 'ron@x.com', 'm1', 'ron@x.com:t1', 'Old <old@y.com>', '',
                 '', '', 's', '2026-01-01 00:00:00', '', '', '', '', 'INBOX', 0, 0),
                ('ron@x.com:m2', 'ron@x.com', 'm2', 'ron@x.com:t1', 'Jane Doe <Jane@Y.com>', '',
                 '', '', 's', '2026-01-02 00:00:00', '', '', '', '', 'INBOX SENT', 0, 0),
                ('ron@x.com:m3', 'ron@x.com', 'm3', 'ron@x.com:t2', 'bare@z.com', '',
                 '', '', 'd', '2026-01-02 00:00:00', '', '', '', '', 'DRAFT', 0, 0)
                """)
        }
        try AppDatabase.migrator.migrate(q)  // through v16/v17

        let cols = try q.read { try $0.columns(in: "thread").map(\.name) }
        for name in ["inSent", "inDrafts", "inPromotions", "inSocial", "fromEmail"] {
            XCTAssertTrue(cols.contains(name), "v16 must add \(name)")
        }

        let (t1, t2) = try q.read { db in
            (try MailThread.fetchOne(db, key: "ron@x.com:t1"),
             try MailThread.fetchOne(db, key: "ron@x.com:t2"))
        }
        XCTAssertEqual(t1?.inSent, true)
        XCTAssertEqual(t1?.inDrafts, false)
        XCTAssertEqual(t1?.inPromotions, true)
        XCTAssertEqual(t1?.inSocial, false)
        XCTAssertEqual(t1?.fromEmail, "jane@y.com", "newest message From, lowercased")

        XCTAssertEqual(t2?.inSent, false)
        XCTAssertEqual(t2?.inDrafts, true)
        XCTAssertEqual(t2?.inPromotions, false)
        XCTAssertEqual(t2?.inSocial, true)
        XCTAssertEqual(t2?.fromEmail, "bare@z.com")
    }

    /// v17 rebuilds message_fts without bodyText (subject + fromHeader only).
    func testUpgradeToV17TrimsFTSBodyText() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v16")
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
        try AppDatabase.migrator.migrate(q)

        let sql = try q.read { db in
            try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'message_fts'") ?? ""
        }
        let lower = sql.lowercased()
        XCTAssertTrue(lower.contains("subject"), "v17 FTS must index subject; got: \(sql)")
        XCTAssertTrue(lower.contains("fromheader") || lower.contains("fromHeader".lowercased()),
                      "v17 FTS must index fromHeader; got: \(sql)")
        XCTAssertFalse(lower.contains("bodytext"),
                       "v17 FTS must not index bodyText; got: \(sql)")
        XCTAssertTrue(lower.contains("prefix"), "v17 must keep prefix indexes; got: \(sql)")

        try q.read { db in
            // Subject still searchable…
            let subj = try Int.fetchOne(db, sql:
                "SELECT count(*) FROM message_fts WHERE message_fts MATCH 'zebra'") ?? 0
            XCTAssertEqual(subj, 1)
            // …but body text is not in the index.
            let body = try Int.fetchOne(db, sql:
                "SELECT count(*) FROM message_fts WHERE message_fts MATCH 'quick'") ?? 0
            XCTAssertEqual(body, 0, "body terms must not be indexed after v17")
        }
    }

    /// v18 adds composite indexes for hot mailbox list filters (including
    /// lastDate so ORDER BY need not sort all matching rows).
    /// Applies cleanly on a pre-seeded DB and leaves existing rows intact.
    func testUpgradeToV18AddsCompositeThreadIndexes() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v17")
        try q.write { db in
            try db.execute(sql: "INSERT INTO account (id, displayName, senderName) VALUES ('ron@x.com', 'P', '')")
            try db.execute(sql: """
                INSERT INTO thread (id, accountId, gmailThreadId, subject, snippet, fromDisplay,
                    lastDate, isUnread, isStarred, inInbox, inTrash, labelIds, participants,
                    messageCount, hasAttachment, inSent, inDrafts, inPromotions, inSocial, fromEmail)
                VALUES
                ('ron@x.com:t1', 'ron@x.com', 't1', 's', 'sn', 'Jane',
                 '2026-01-02 00:00:00', 1, 0, 1, 0, 'INBOX', 'Jane', 1, 0, 0, 0, 0, 0, 'jane@y.com')
                """)
        }
        try AppDatabase.migrator.migrate(q)

        let indexNames = try q.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'index' AND tbl_name = 'thread' AND name LIKE 'thread_on_%'
                ORDER BY name
                """)
        }
        let expected = [
            "thread_on_accountId_lastDate",
            "thread_on_inDrafts_inTrash_lastDate",
            "thread_on_inInbox_inTrash_lastDate",
            "thread_on_inPromotions_inTrash_lastDate",
            "thread_on_inSent_inTrash_lastDate",
            "thread_on_inSocial_inTrash_lastDate",
            "thread_on_isStarred_inTrash_lastDate",
        ]
        for name in expected {
            XCTAssertTrue(indexNames.contains(name), "missing index \(name); got \(indexNames)")
        }

        // Pre-seeded row survives the index-only migration.
        let thread = try q.read { try MailThread.fetchOne($0, key: "ron@x.com:t1") }
        XCTAssertEqual(thread?.fromEmail, "jane@y.com")
        XCTAssertEqual(thread?.inInbox, true)
    }

    /// v19 adds inSpam and backfills from labelIds (exact token, not substring).
    func testUpgradeToV19AddsInSpamAndBackfills() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v18")
        try q.write { db in
            try db.execute(sql: "INSERT INTO account (id, displayName, senderName) VALUES ('ron@x.com', 'P', '')")
            try db.execute(sql: """
                INSERT INTO thread (id, accountId, gmailThreadId, subject, snippet, fromDisplay,
                    lastDate, isUnread, isStarred, inInbox, inTrash, labelIds, participants,
                    messageCount, hasAttachment, inSent, inDrafts, inPromotions, inSocial, fromEmail)
                VALUES
                ('ron@x.com:t1', 'ron@x.com', 't1', 's', 'sn', 'Spam',
                 '2026-01-02 00:00:00', 1, 0, 0, 0, 'SPAM CATEGORY_PROMOTIONS', 'Spam', 1, 0,
                 0, 0, 1, 0, 'spam@x.com'),
                ('ron@x.com:t2', 'ron@x.com', 't2', 's', 'sn', 'Ok',
                 '2026-01-02 00:00:00', 1, 0, 1, 0, 'INBOX CATEGORY_PROMOTIONS', 'Ok', 1, 0,
                 0, 0, 1, 0, 'ok@x.com'),
                ('ron@x.com:t3', 'ron@x.com', 't3', 's', 'sn', 'Only',
                 '2026-01-02 00:00:00', 0, 0, 0, 0, 'SPAM', 'Only', 1, 0,
                 0, 0, 0, 0, 'only@x.com')
                """)
        }
        try AppDatabase.migrator.migrate(q)

        let cols = try q.read { try $0.columns(in: "thread").map(\.name) }
        XCTAssertTrue(cols.contains("inSpam"), "v19 must add inSpam")

        let (t1, t2, t3) = try q.read { db in
            (try MailThread.fetchOne(db, key: "ron@x.com:t1"),
             try MailThread.fetchOne(db, key: "ron@x.com:t2"),
             try MailThread.fetchOne(db, key: "ron@x.com:t3"))
        }
        XCTAssertEqual(t1?.inSpam, true)
        XCTAssertEqual(t1?.inPromotions, true)
        XCTAssertEqual(t2?.inSpam, false)
        XCTAssertEqual(t3?.inSpam, true)
    }
}
