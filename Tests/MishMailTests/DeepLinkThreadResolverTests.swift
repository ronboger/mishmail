import XCTest
import GRDB

/// `mishmail://thread/<token>` resolution: primary-key probes first (row ids
/// are `"<account>:<gmailId>"`), unindexed token scans only as a fallback.
final class DeepLinkThreadResolverTests: XCTestCase {

    private let work = "work@x.com"
    private let personal = "me@gmail.com"

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            for id in [work, personal] {
                try Account(id: id, displayName: id, historyId: nil,
                            lastSyncAt: nil, senderName: "").insert(db)
            }
        }
        return q
    }

    /// One thread (`<account>:<gmailThreadId>`) with one message
    /// (`<account>:<gmailMessageId>`) — the production id format.
    private func seed(_ db: Database, account: String, gmailThreadId: String,
                      gmailMessageId: String, date: Date) throws {
        let threadId = "\(account):\(gmailThreadId)"
        var t = MailThread(
            id: threadId, accountId: account, gmailThreadId: gmailThreadId,
            subject: "s", snippet: "sn", fromDisplay: "F",
            lastDate: date, isUnread: false, isStarred: false,
            inInbox: true, inTrash: false,
            labelIds: "INBOX", snoozeUntil: nil, participants: "F",
            messageCount: 1, hasAttachment: false, reminderAt: nil)
        t.syncFlagsFromLabelIds()
        try t.insert(db)
        try Message(
            id: "\(account):\(gmailMessageId)", accountId: account,
            gmailId: gmailMessageId, threadId: threadId,
            fromHeader: "a@b.c", toHeader: account, ccHeader: "",
            subject: "s", date: date, snippet: "sn", bodyText: "",
            bodyHTML: nil, messageIdHeader: "<\(gmailMessageId)@x>",
            referencesHeader: "", labelIds: "INBOX", isUnread: false,
            hasAttachment: false).insert(db)
    }

    private func resolve(_ q: DatabaseQueue, token: String, account: String?,
                         known: [String]? = nil) throws -> String? {
        try q.read { db in
            try DeepLinkThreadResolver.resolve(
                db: db, token: token, accountEmail: account,
                knownAccountIds: known ?? [self.work, self.personal])?.id
        }
    }

    // MARK: - Primary keys (pure)

    func testPrimaryKeysWithAccountAddCaseInsensitiveCanonicalMatch() {
        XCTAssertEqual(
            DeepLinkThreadResolver.primaryKeys(
                token: "T1", accountEmail: "Work@X.com",
                knownAccountIds: [work, personal]),
            ["Work@X.com:T1", "work@x.com:T1"])
    }

    func testPrimaryKeysWithExactAccountAreNotDuplicated() {
        XCTAssertEqual(
            DeepLinkThreadResolver.primaryKeys(
                token: "T1", accountEmail: work, knownAccountIds: [work, personal]),
            ["work@x.com:T1"])
    }

    func testPrimaryKeysWithoutAccountProbeEveryLinkedAccount() {
        XCTAssertEqual(
            DeepLinkThreadResolver.primaryKeys(
                token: "T1", accountEmail: nil, knownAccountIds: [work, personal]),
            ["work@x.com:T1", "me@gmail.com:T1"])
        XCTAssertEqual(
            DeepLinkThreadResolver.primaryKeys(
                token: "T1", accountEmail: nil, knownAccountIds: []),
            [])
    }

    // MARK: - Resolution

    func testThreadTokenWithAccountResolvesByKey() throws {
        let q = try makeDB()
        try q.write { db in
            try seed(db, account: work, gmailThreadId: "t1", gmailMessageId: "m1", date: Date())
        }
        XCTAssertEqual(try resolve(q, token: "t1", account: work), "work@x.com:t1")
        // Differently cased account still resolves (canonical key probe).
        XCTAssertEqual(try resolve(q, token: "t1", account: "WORK@x.com"), "work@x.com:t1")
    }

    func testMessageTokenResolvesToItsThread() throws {
        let q = try makeDB()
        try q.write { db in
            try seed(db, account: work, gmailThreadId: "t1", gmailMessageId: "m1", date: Date())
        }
        XCTAssertEqual(try resolve(q, token: "m1", account: work), "work@x.com:t1")
        XCTAssertEqual(try resolve(q, token: "m1", account: nil), "work@x.com:t1")
    }

    func testNoAccountPicksNewestAcrossAccounts() throws {
        let q = try makeDB()
        let now = Date()
        try q.write { db in
            try seed(db, account: work, gmailThreadId: "t1", gmailMessageId: "m1",
                     date: now.addingTimeInterval(-3600))
            try seed(db, account: personal, gmailThreadId: "t1", gmailMessageId: "m2",
                     date: now)
        }
        XCTAssertEqual(try resolve(q, token: "t1", account: nil), "me@gmail.com:t1")
    }

    func testFallbackScanFindsThreadForUnlinkedAccountCasing() throws {
        let q = try makeDB()
        try q.write { db in
            try seed(db, account: work, gmailThreadId: "t1", gmailMessageId: "m1", date: Date())
        }
        // No linked accounts known (e.g. list not loaded): key probes miss on
        // casing, the lower(accountId) scan still resolves it.
        XCTAssertEqual(try resolve(q, token: "t1", account: "WORK@X.COM", known: []),
                       "work@x.com:t1")
        XCTAssertEqual(try resolve(q, token: "m1", account: "WORK@X.COM", known: []),
                       "work@x.com:t1")
        XCTAssertEqual(try resolve(q, token: "t1", account: nil, known: []),
                       "work@x.com:t1")
    }

    func testUnknownTokenIsNil() throws {
        let q = try makeDB()
        XCTAssertNil(try resolve(q, token: "nope", account: work))
        XCTAssertNil(try resolve(q, token: "nope", account: nil))
    }

    /// The key probes are what keep the common case off a full SQLCipher
    /// scan — pin them to primary-key searches.
    func testKeyProbesSearchByPrimaryKey() throws {
        let q = try makeDB()
        try q.read { db in
            for sql in ["SELECT * FROM thread WHERE id = ?",
                        "SELECT threadId, date FROM message WHERE id = ?"] {
                let detail = try Row.fetchAll(
                    db, sql: "EXPLAIN QUERY PLAN \(sql)", arguments: ["k"])
                    .map { $0["detail"] as String? ?? "" }
                    .joined(separator: " | ")
                XCTAssertTrue(detail.hasPrefix("SEARCH"), "\(sql): \(detail)")
                XCTAssertTrue(
                    detail.localizedCaseInsensitiveContains("INDEX")
                        || detail.localizedCaseInsensitiveContains("PRIMARY KEY"),
                    "\(sql): \(detail)")
            }
        }
    }
}
