import XCTest
import GRDB

/// Replay of queued thread edits: one account that cannot authenticate (or
/// was removed) must not block the edits of the other accounts.
final class ThreadOpReplayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func disposition(_ error: Error, known: Bool = true,
                             age: TimeInterval = 60) -> ThreadOpReplay.Disposition {
        ThreadOpReplay.replayDisposition(
            error: error, accountIsKnown: known,
            createdAt: now.addingTimeInterval(-age), now: now)
    }

    // MARK: - Disposition

    func testConnectivityFailureStopsThePass() {
        XCTAssertEqual(disposition(URLError(.notConnectedToInternet)), .stopPass)
        XCTAssertEqual(disposition(URLError(.timedOut)), .stopPass)
    }

    func testReauthSkipsTheAccountAndKeepsTheRow() {
        XCTAssertEqual(disposition(GmailError.noRefreshToken("a@x.com")),
                       .skipAccount(reauthorize: true))
        XCTAssertEqual(disposition(OAuthError.invalidGrant),
                       .skipAccount(reauthorize: true))
    }

    func testUnknownAccountDropsTheRowWhateverTheError() {
        let drop = ThreadOpReplay.Disposition.dropRow(revert: false, report: false)
        XCTAssertEqual(disposition(GmailError.noRefreshToken("a@x.com"), known: false), drop)
        XCTAssertEqual(disposition(URLError(.notConnectedToInternet), known: false), drop)
        XCTAssertEqual(disposition(GmailError.http(503, ""), known: false), drop)
        XCTAssertEqual(disposition(GmailError.http(400, ""), known: false), drop)
    }

    func testRateLimitSkipsTheAccountWithoutReauth() {
        XCTAssertEqual(disposition(GmailError.http(429, "")),
                       .skipAccount(reauthorize: false))
    }

    func testServerErrorKeepsTheRow() {
        XCTAssertEqual(disposition(GmailError.http(503, "")), .keepRow)
    }

    func testExpiredRowIsDroppedOnAServerFailure() {
        let old = ThreadEditRetryPolicy.maxQueuedAge + 60
        let drop = ThreadOpReplay.Disposition.dropRow(revert: true, report: true)
        XCTAssertEqual(disposition(GmailError.http(503, ""), age: old), drop)
        XCTAssertEqual(disposition(GmailError.http(429, ""), age: old), drop)
        // Age alone never drops a row: offline and reauth rows wait.
        XCTAssertEqual(disposition(URLError(.notConnectedToInternet), age: old), .stopPass)
        XCTAssertEqual(disposition(GmailError.noRefreshToken("a@x.com"), age: old),
                       .skipAccount(reauthorize: true))
    }

    func testRejectionDropsAndReverts() {
        XCTAssertEqual(disposition(GmailError.http(400, "bad")),
                       .dropRow(revert: true, report: true))
        // The thread is gone in Gmail: nothing to tell the user.
        XCTAssertEqual(disposition(GmailError.http(404, "")),
                       .dropRow(revert: true, report: false))
    }

    // MARK: - Pass state

    func testSkippedAccountDoesNotBlockTheOthers() {
        var pass = ThreadOpReplay.Pass()
        XCTAssertFalse(pass.skips("a@x.com"))
        pass.skip("a@x.com")
        XCTAssertTrue(pass.skips("a@x.com"))
        XCTAssertFalse(pass.skips("b@x.com"))
    }

    func testRepeatedServerErrorsSkipOnlyThatAccount() {
        var pass = ThreadOpReplay.Pass()
        for _ in 0..<(ThreadEditRetryPolicy.maxServerFailuresPerPass - 1) {
            pass.recordServerError("a@x.com")
        }
        XCTAssertFalse(pass.skips("a@x.com"))
        pass.recordServerError("b@x.com")
        pass.recordServerError("a@x.com")
        XCTAssertTrue(pass.skips("a@x.com"))
        XCTAssertFalse(pass.skips("b@x.com"))
    }

    // MARK: - Rows of a removed account

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: "b@x.com", displayName: "B", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            try PendingThreadOp.enqueue(db, accountId: "gone@x.com", gmailThreadId: "t1",
                                        change: .modify(remove: ["INBOX"]))
            try PendingThreadOp.enqueue(db, accountId: "b@x.com", gmailThreadId: "t1",
                                        change: .modify(add: ["STARRED"]))
        }
        return q
    }

    func testOrphanRowIsDeletedAndAKnownAccountRowStays() throws {
        let q = try makeDB()
        let rows = try q.read { try PendingThreadOp.order(Column("accountId")).fetchAll($0) }
        XCTAssertEqual(rows.map(\.accountId), ["b@x.com", "gone@x.com"])
        try q.write { db in
            XCTAssertFalse(try PendingThreadOp.deleteIfAccountMissing(db, row: rows[0]))
            XCTAssertTrue(try PendingThreadOp.deleteIfAccountMissing(db, row: rows[1]))
        }
        let left = try q.read { try PendingThreadOp.fetchAll($0) }
        XCTAssertEqual(left.map(\.accountId), ["b@x.com"])
        XCTAssertEqual(left.first?.change, .modify(add: ["STARRED"]))
    }
}
