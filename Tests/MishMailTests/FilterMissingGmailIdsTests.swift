import XCTest
import GRDB

/// SyncEngine.filterMissingGmailIds — per-page existence filter used by
/// fetchAll so backfill never loads every gmailId into a Set.
final class FilterMissingGmailIdsTests: XCTestCase {

    private let account = "ron@x.com"

    private func migrate() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
        }
        return q
    }

    private func seed(_ q: DatabaseQueue, gmailIds: [String]) throws {
        try q.write { db in
            for id in gmailIds {
                try Message(
                    id: "\(account):\(id)", accountId: account, gmailId: id,
                    threadId: "\(account):t1", fromHeader: "a@b.com", toHeader: account,
                    ccHeader: "", bccHeader: "", subject: "s", date: Date(),
                    snippet: "", bodyText: "", bodyHTML: nil, messageIdHeader: "",
                    referencesHeader: "", labelIds: "INBOX", isUnread: false,
                    hasAttachment: false).save(db)
            }
        }
    }

    func testEmptyListedReturnsEmpty() throws {
        let q = try migrate()
        let missing = try q.read {
            try SyncEngine.filterMissingGmailIds($0, accountId: account, listed: [])
        }
        XCTAssertEqual(missing, [])
    }

    func testAllMissingWhenCacheEmpty() throws {
        let q = try migrate()
        let listed = ["a", "b", "c"]
        let missing = try q.read {
            try SyncEngine.filterMissingGmailIds($0, accountId: account, listed: listed)
        }
        XCTAssertEqual(missing, listed)
    }

    func testOnlyMissingReturnedWhenMixOfCachedAndNew() throws {
        let q = try migrate()
        try seed(q, gmailIds: ["cached1", "cached2", "cached3"])
        // List page mixes existing + new (as Gmail list would during window expand).
        let listed = ["cached2", "new1", "cached1", "new2", "cached3"]
        let missing = try q.read {
            try SyncEngine.filterMissingGmailIds($0, accountId: account, listed: listed)
        }
        XCTAssertEqual(missing, ["new1", "new2"],
                       "must not re-download cached; must not skip truly missing")
    }

    func testDedupesListedPreservingOrder() throws {
        let q = try migrate()
        try seed(q, gmailIds: ["have"])
        let listed = ["new", "have", "new", "also-new", "have"]
        let missing = try q.read {
            try SyncEngine.filterMissingGmailIds($0, accountId: account, listed: listed)
        }
        XCTAssertEqual(missing, ["new", "also-new"])
    }

    func testOtherAccountDoesNotCountAsCached() throws {
        let q = try migrate()
        try q.write { db in
            try Account(id: "other@x.com", displayName: "O", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            try Message(
                id: "other@x.com:shared-id", accountId: "other@x.com", gmailId: "shared-id",
                threadId: "other@x.com:t1", fromHeader: "", toHeader: "",
                ccHeader: "", bccHeader: "", subject: "", date: Date(),
                snippet: "", bodyText: "", bodyHTML: nil, messageIdHeader: "",
                referencesHeader: "", labelIds: "", isUnread: false,
                hasAttachment: false).save(db)
        }
        // Same Gmail id under another account must still be treated as missing.
        let missing = try q.read {
            try SyncEngine.filterMissingGmailIds($0, accountId: account,
                                                 listed: ["shared-id", "only-here"])
        }
        XCTAssertEqual(missing, ["shared-id", "only-here"])
    }

    func testAllCachedReturnsEmpty() throws {
        let q = try migrate()
        try seed(q, gmailIds: ["a", "b"])
        let missing = try q.read {
            try SyncEngine.filterMissingGmailIds($0, accountId: account, listed: ["a", "b"])
        }
        XCTAssertEqual(missing, [])
    }
}
