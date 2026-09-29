import XCTest
import GRDB

/// Optimistic thread edits (archive, star, mark read, labels) write the
/// thread row only. Message rows keep Gmail's last known labels until
/// history reports the edit, so a rejected edit reverts by re-deriving the
/// thread from those rows.
final class OptimisticThreadRevertTests: XCTestCase {
    private let account = "ron@x.com"
    private var threadId: String { "\(account):t1" }

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: self.account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            for (id, labels) in [("m1", "INBOX UNREAD"), ("m2", "INBOX")] {
                try Message(id: "\(self.account):\(id)", accountId: self.account, gmailId: id,
                            threadId: self.threadId, fromHeader: "a@b.com",
                            toHeader: self.account, ccHeader: "", bccHeader: "",
                            subject: "Hello", date: Date(), snippet: "", bodyText: "",
                            bodyHTML: nil, messageIdHeader: "", referencesHeader: "",
                            labelIds: labels, isUnread: labels.contains("UNREAD"),
                            hasAttachment: false).insert(db)
            }
            try SyncEngine.deriveThreads(db, for: [self.threadId], accountId: self.account)
        }
        return q
    }

    private func thread(_ q: DatabaseQueue) throws -> MailThread {
        try XCTUnwrap(try q.read { try MailThread.fetchOne($0, key: self.threadId) })
    }

    private func messageLabels(_ q: DatabaseQueue) throws -> [String] {
        try q.read { db in
            try String.fetchAll(db, sql: "SELECT labelIds FROM message ORDER BY id")
        }
    }

    func testOptimisticArchiveTouchesOnlyTheThreadRow() throws {
        let q = try makeDB()
        let before = try thread(q)
        var archived = before
        archived.inInbox = false
        archived.isUnread = false
        archived.labelIds = "UNREAD"
        try q.write { db in
            try OptimisticThreadWrite.updateChangedColumns(db, from: before, to: archived)
        }
        XCTAssertFalse(try thread(q).inInbox)
        XCTAssertEqual(try messageLabels(q), ["INBOX UNREAD", "INBOX"])
    }

    func testRejectedEditRevertsFromMessageRows() throws {
        let q = try makeDB()
        let before = try thread(q)
        var archived = before
        archived.inInbox = false
        archived.isUnread = false
        archived.labelIds = ""
        try q.write { db in
            try OptimisticThreadWrite.updateChangedColumns(db, from: before, to: archived)
            try OptimisticThreadWrite.rederiveOrDelete(db, threadId: self.threadId, accountId: self.account)
        }
        let reverted = try thread(q)
        XCTAssertTrue(reverted.inInbox)
        XCTAssertTrue(reverted.isUnread)
        XCTAssertEqual(reverted.labelIds, "INBOX UNREAD")
    }

    /// A successful edit shows once history patches the message rows and
    /// the thread re-derives from them.
    func testHistoryPatchThenDeriveKeepsTheEdit() throws {
        let q = try makeDB()
        try q.write { db in
            for id in ["m1", "m2"] {
                let key = "\(self.account):\(id)"
                let current = try String.fetchOne(
                    db, sql: "SELECT labelIds FROM message WHERE id = ?", arguments: [key]) ?? ""
                let labels = SyncEngine.applyLabelDelta(labelIds: current, add: [], remove: ["INBOX"])
                try db.execute(sql: "UPDATE message SET labelIds = ? WHERE id = ?",
                               arguments: [labels, key])
            }
            try SyncEngine.deriveThreads(db, for: [self.threadId], accountId: self.account)
        }
        XCTAssertFalse(try thread(q).inInbox)
    }

    /// Only changed columns are written, so a newer sync-derived value in
    /// another column survives the optimistic write.
    func testOnlyChangedColumnsAreWritten() throws {
        let q = try makeDB()
        let stale = try thread(q)
        try q.write { db in
            try db.execute(sql: "UPDATE thread SET subject = 'Newer' WHERE id = ?",
                           arguments: [self.threadId])
        }
        var starred = stale
        starred.isStarred = true
        try q.write { db in
            try OptimisticThreadWrite.updateChangedColumns(db, from: stale, to: starred)
        }
        let row = try thread(q)
        XCTAssertTrue(row.isStarred)
        XCTAssertEqual(row.subject, "Newer")
    }

    func testRevertDeletesAThreadWithNoMessages() throws {
        let q = try makeDB()
        try q.write { db in
            try db.execute(sql: "DELETE FROM message")
            try OptimisticThreadWrite.rederiveOrDelete(db, threadId: self.threadId, accountId: self.account)
        }
        XCTAssertNil(try q.read { try MailThread.fetchOne($0, key: self.threadId) })
    }
}
