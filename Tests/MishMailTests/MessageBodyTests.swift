import XCTest
import GRDB

final class MessageBodyTests: XCTestCase {
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

    func testUpsertSplitsBodyOffRow() throws {
        let q = try makeDB()
        let threadId = "\(account):t1"
        let msg = Message(
            id: "\(account):m1", accountId: account, gmailId: "m1",
            threadId: threadId, fromHeader: "A <a@x.com>", toHeader: "me",
            ccHeader: "", subject: "Hello", date: Date(), snippet: "hi",
            bodyText: "plain body", bodyHTML: "<p>html</p>",
            messageIdHeader: "<1>", referencesHeader: "",
            labelIds: "INBOX", isUnread: true, hasAttachment: false)
        try q.write { db in
            _ = try SyncEngine.upsertPending(db, items: [
                .init(message: msg, attachments: [])
            ])
        }
        try q.read { db in
            let row = try Message.fetchOne(db, key: "\(account):m1")
            XCTAssertEqual(row?.bodyText, "", "on-row body must be empty after upsert")
            XCTAssertNil(row?.bodyHTML)
            let body = try MessageBody.fetchOne(db, key: "\(account):m1")
            XCTAssertEqual(body?.bodyText, "plain body")
            XCTAssertEqual(body?.bodyHTML, "<p>html</p>")
        }
    }

    func testDeleteMessageCascadesBody() throws {
        let q = try makeDB()
        try q.write { db in
            let msg = Message(
                id: "\(account):m1", accountId: account, gmailId: "m1",
                threadId: "\(account):t1", fromHeader: "A", toHeader: "me",
                ccHeader: "", subject: "s", date: Date(), snippet: "",
                bodyText: "x", bodyHTML: nil, messageIdHeader: "",
                referencesHeader: "", labelIds: "INBOX", isUnread: false,
                hasAttachment: false)
            _ = try SyncEngine.upsertPending(db, items: [.init(message: msg, attachments: [])])
            try Message.deleteOne(db, key: "\(account):m1")
        }
        let n = try q.read {
            try Int.fetchOne($0, sql: "SELECT count(*) FROM message_body") ?? -1
        }
        XCTAssertEqual(n, 0)
    }

    func testV24MigrationPreservesBodyContent() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v23")
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO account (id, displayName, senderName) VALUES ('a@x.com', 'A', '')
                """)
            try db.execute(sql: """
                INSERT INTO message (
                    id, accountId, gmailId, threadId, fromHeader, toHeader, ccHeader,
                    subject, date, snippet, bodyText, bodyHTML, messageIdHeader,
                    referencesHeader, labelIds, isUnread, hasAttachment, bccHeader)
                VALUES (
                    'a@x.com:m1', 'a@x.com', 'm1', 'a@x.com:t1', 'F', 'T', '',
                    'S', '2026-01-01', 'sn', 'keep-text', '<b>h</b>', '',
                    '', 'INBOX', 0, 0, '')
                """)
        }
        try AppDatabase.migrator.migrate(q)
        try q.read { db in
            let body = try MessageBody.fetchOne(db, key: "a@x.com:m1")
            XCTAssertEqual(body?.bodyText, "keep-text")
            XCTAssertEqual(body?.bodyHTML, "<b>h</b>")
            let msg = try Message.fetchOne(db, key: "a@x.com:m1")
            XCTAssertEqual(msg?.bodyText, "")
        }
    }
}
