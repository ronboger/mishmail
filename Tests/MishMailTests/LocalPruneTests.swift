import XCTest
import GRDB

/// SyncEngine.pruneMessages — removing mail from this Mac (Gmail untouched).
final class LocalPruneTests: XCTestCase {

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        return q
    }

    private func insert(_ db: Database, account: String, gmailId: String,
                        daysAgo: Double, labelIds: String = "INBOX") throws {
        try Message(
            id: "\(account):\(gmailId)", accountId: account, gmailId: gmailId,
            threadId: "\(account):t-\(gmailId)", fromHeader: "a@b.com", toHeader: account,
            ccHeader: "", bccHeader: "", subject: "s",
            date: Date().addingTimeInterval(-daysAgo * 86_400),
            snippet: "", bodyText: "", bodyHTML: nil, messageIdHeader: "",
            referencesHeader: "", labelIds: labelIds, isUnread: false,
            hasAttachment: false).save(db)
    }

    /// Narrowing the window deletes older mail but keeps recent and starred.
    func testPruneKeepsRecentAndStarred() throws {
        let q = try makeDB()
        try q.write { db in
            try Account(id: "ron@x.com", displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            try self.insert(db, account: "ron@x.com", gmailId: "new", daysAgo: 5)
            try self.insert(db, account: "ron@x.com", gmailId: "old", daysAgo: 200)
            try self.insert(db, account: "ron@x.com", gmailId: "oldstar", daysAgo: 200,
                            labelIds: "INBOX STARRED")
        }
        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        try q.write { db in
            try SyncEngine.pruneMessages(db, accountId: "ron@x.com", olderThan: cutoff)
        }
        let remaining = try q.read { db in
            try String.fetchSet(db, sql: "SELECT gmailId FROM message")
        }
        XCTAssertEqual(remaining, ["new", "oldstar"])
    }

    /// A nil cutoff ("Nothing") removes everything, starred included.
    func testPruneAllRemovesEverything() throws {
        let q = try makeDB()
        try q.write { db in
            try Account(id: "ron@x.com", displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            try self.insert(db, account: "ron@x.com", gmailId: "m1", daysAgo: 1)
            try self.insert(db, account: "ron@x.com", gmailId: "m2", daysAgo: 500,
                            labelIds: "STARRED")
        }
        try q.write { db in
            try SyncEngine.pruneMessages(db, accountId: "ron@x.com", olderThan: nil)
        }
        XCTAssertEqual(try q.read { db in try Message.fetchCount(db) }, 0)
    }

    /// Pruning one account never touches another account's mail.
    func testPruneIsScopedToAccount() throws {
        let q = try makeDB()
        try q.write { db in
            try Account(id: "ron@x.com", displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            try Account(id: "ron@work.com", displayName: "W", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            try self.insert(db, account: "ron@x.com", gmailId: "m1", daysAgo: 400)
            try self.insert(db, account: "ron@work.com", gmailId: "m2", daysAgo: 400)
        }
        try q.write { db in
            try SyncEngine.pruneMessages(db, accountId: "ron@x.com", olderThan: nil)
        }
        let remaining = try q.read { db in
            try String.fetchSet(db, sql: "SELECT accountId FROM message")
        }
        XCTAssertEqual(remaining, ["ron@work.com"])
    }

    /// Deleting messages cascades to their attachments.
    func testPruneCascadesAttachments() throws {
        let q = try makeDB()
        try q.write { db in
            try Account(id: "ron@x.com", displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            try self.insert(db, account: "ron@x.com", gmailId: "m1", daysAgo: 400)
            var att = AttachmentRow(id: nil, messageId: "ron@x.com:m1",
                                    gmailAttachmentId: "a1", filename: "f.pdf",
                                    mimeType: "application/pdf", size: 1)
            try att.insert(db)
        }
        try q.write { db in
            try SyncEngine.pruneMessages(db, accountId: "ron@x.com", olderThan: nil)
        }
        XCTAssertEqual(try q.read { db in try AttachmentRow.fetchCount(db) }, 0)
    }
}
