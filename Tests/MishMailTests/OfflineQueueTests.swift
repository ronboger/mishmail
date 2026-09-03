import XCTest
import GRDB

/// Persistence of the offline queues (v38): thread edits fold into one row
/// per thread; drafts saved offline round-trip with their attachments.
final class OfflineQueueTests: XCTestCase {
    private let account = "a@x.com"

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        return q
    }

    func testEnqueueCreatesOneRowPerThreadAndFolds() throws {
        let q = try makeDB()
        try q.write { db in
            try PendingThreadOp.enqueue(db, accountId: account, gmailThreadId: "t1",
                                        change: .modify(add: ["STARRED"]))
            try PendingThreadOp.enqueue(db, accountId: account, gmailThreadId: "t1",
                                        change: .modify(remove: ["INBOX", "UNREAD"]))
            try PendingThreadOp.enqueue(db, accountId: account, gmailThreadId: "t2",
                                        change: .trash)
        }
        try q.read { db in
            let rows = try PendingThreadOp.order(Column("gmailThreadId")).fetchAll(db)
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows[0].gmailThreadId, "t1")
            XCTAssertEqual(rows[0].change,
                           .modify(add: ["STARRED"], remove: ["INBOX", "UNREAD"]))
            XCTAssertEqual(rows[1].change, .trash)
        }
    }

    func testEnqueueThatCancelsOutDeletesTheRow() throws {
        let q = try makeDB()
        try q.write { db in
            try PendingThreadOp.enqueue(db, accountId: account, gmailThreadId: "t1",
                                        change: .modify(remove: ["INBOX"]))
            try PendingThreadOp.enqueue(db, accountId: account, gmailThreadId: "t1",
                                        change: .modify(add: ["INBOX"]))
        }
        try q.read { db in
            XCTAssertEqual(try PendingThreadOp.fetchCount(db), 0)
        }
    }

    func testEmptyChangeIsNotQueued() throws {
        let q = try makeDB()
        try q.write { db in
            try PendingThreadOp.enqueue(db, accountId: account, gmailThreadId: "t1",
                                        change: .modify())
        }
        try q.read { db in
            XCTAssertEqual(try PendingThreadOp.fetchCount(db), 0)
        }
    }

    func testSameThreadIdOnAnotherAccountIsSeparate() throws {
        let q = try makeDB()
        try q.write { db in
            try PendingThreadOp.enqueue(db, accountId: "a@x.com", gmailThreadId: "t1",
                                        change: .modify(add: ["STARRED"]))
            try PendingThreadOp.enqueue(db, accountId: "b@x.com", gmailThreadId: "t1",
                                        change: .modify(add: ["STARRED"]))
        }
        try q.read { db in
            XCTAssertEqual(try PendingThreadOp.fetchCount(db), 2)
        }
    }

    func testLocalDraftRoundTripsWithAttachments() throws {
        let q = try makeDB()
        let attachment = MIMEBuilder.Attachment(
            filename: "notes.txt", mimeType: "text/plain", data: Data("hi".utf8))
        let now = Date()
        let row = LocalDraft(
            id: nil, accountId: account, fromEmail: "",
            toHeader: "b@x.com", ccHeader: "", bccHeader: "",
            subject: "On the plane", body: "Landing soon.",
            replyToMessageId: nil, forward: false,
            replacingDraftId: nil,
            attachmentsJSON: ScheduledSend.encodeAttachments([attachment]),
            createdAt: now, updatedAt: now)
        try q.write { db in try row.insert(db) }
        let fetched = try q.read { db in
            try LocalDraft.order(Column("updatedAt").desc).fetchAll(db)
        }
        XCTAssertEqual(fetched.count, 1)
        XCTAssertNotNil(fetched[0].id)
        XCTAssertEqual(fetched[0].subject, "On the plane")
        XCTAssertEqual(fetched[0].effectiveFromEmail, account)
        XCTAssertEqual(fetched[0].attachments.map(\.filename), ["notes.txt"])
        XCTAssertEqual(fetched[0].attachments.first?.data, Data("hi".utf8))
    }
}
