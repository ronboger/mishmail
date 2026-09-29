import XCTest
import GRDB

/// SQLite rejects a statement that binds more than 32766 variables. A large
/// delete in Gmail (tens of thousands of messages) used to reach the history
/// and orphan-removal statements as one `IN (...)` list, which threw on every
/// pass, so the history id never advanced.
final class BoundedSQLTests: XCTestCase {
    private let account = "ron@x.com"
    /// More ids than SQLite's variable limit.
    private let bigCount = 33_500

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: self.account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
        }
        return q
    }

    private func message(_ gmailId: String, thread: String) -> Message {
        Message(id: "\(account):\(gmailId)", accountId: account, gmailId: gmailId,
                threadId: "\(account):\(thread)", fromHeader: "a@b.com", toHeader: account,
                ccHeader: "", bccHeader: "", subject: "s", date: Date(),
                snippet: "", bodyText: "", bodyHTML: nil, messageIdHeader: "",
                referencesHeader: "", labelIds: "INBOX", isUnread: false,
                hasAttachment: false)
    }

    func testChunksNeverExceedTheBindLimit() {
        let chunks = SyncEngine.sqlChunks(Array(0..<1_201))
        XCTAssertEqual(chunks.map(\.count), [500, 500, 201])
        XCTAssertTrue(SyncEngine.sqlChunks([Int]()).isEmpty)
    }

    func testDeletingMoreIdsThanSQLiteCanBindSucceeds() throws {
        let q = try makeDB()
        // Two threads keep a message each; everything else goes.
        try q.write { db in
            for i in 0..<bigCount {
                try self.message("m\(i)", thread: "t\(i % 3)").insert(db)
            }
            try self.message("keep1", thread: "t1").insert(db)
            try self.message("keep2", thread: "t2").insert(db)
            try SyncEngine.deriveThreads(
                db, for: ["\(self.account):t0", "\(self.account):t1", "\(self.account):t2"],
                accountId: self.account)
        }
        let ids = (0..<bigCount).map { "\(account):m\($0)" }
        let keys = try q.write { db in
            try SyncEngine.deleteMessages(db, localIds: ids)
        }
        XCTAssertEqual(keys, ["\(account):t0", "\(account):t1", "\(account):t2"])
        XCTAssertEqual(try q.read { try Message.fetchCount($0) }, 2)

        // Orphan removal with more keys than the limit (most name no thread).
        var manyKeys = Set((0..<bigCount).map { "\(account):ghost\($0)" })
        manyKeys.formUnion(keys)
        try q.write { db in
            try SyncEngine.removeOrphanedThreads(db, accountId: self.account, keys: manyKeys)
        }
        let threads = try q.read { db in try String.fetchSet(db, sql: "SELECT id FROM thread") }
        XCTAssertEqual(threads, ["\(account):t1", "\(account):t2"])
    }

    func testExistenceLookupsHandleMoreIdsThanSQLiteCanBind() throws {
        let q = try makeDB()
        try q.write { db in
            try self.message("present", thread: "t").insert(db)
        }
        let listed = (0..<bigCount).map { "g\($0)" } + ["present"]
        let missing = try q.read { db in
            try SyncEngine.filterMissingGmailIds(db, accountId: self.account, listed: listed)
        }
        XCTAssertEqual(missing.count, bigCount)
        XCTAssertFalse(missing.contains("present"))
        let existing = try q.read { db in
            try SyncEngine.existingMessageIds(db, localIds: listed.map { "\(self.account):\($0)" })
        }
        XCTAssertEqual(existing, ["\(account):present"])
    }
}
