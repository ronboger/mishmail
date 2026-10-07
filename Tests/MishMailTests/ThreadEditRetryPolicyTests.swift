import XCTest

/// A thread edit that Gmail answers with a quota or server error is kept and
/// replayed, not reverted. A rejection (4xx) still reverts.
final class ThreadEditRetryPolicyTests: XCTestCase {
    private let rateLimitBody = """
        {"error":{"code":403,"errors":[{"domain":"usageLimits","reason":"userRateLimitExceeded"}]}}
        """

    func testQuotaAndServerErrorsRequeue() {
        XCTAssertTrue(ThreadEditRetryPolicy.shouldRequeue(GmailError.http(429, "")))
        XCTAssertTrue(ThreadEditRetryPolicy.shouldRequeue(GmailError.http(403, rateLimitBody)))
        for code in [500, 502, 503, 504, 599] {
            XCTAssertTrue(ThreadEditRetryPolicy.shouldRequeue(GmailError.http(code, "")), "\(code)")
        }
    }

    func testRejectionsDoNotRequeue() {
        for code in [400, 401, 404, 409, 412] {
            XCTAssertFalse(ThreadEditRetryPolicy.shouldRequeue(GmailError.http(code, "")), "\(code)")
        }
        // A plain 403 is a permission or scope failure; a retry cannot fix it.
        XCTAssertFalse(ThreadEditRetryPolicy.shouldRequeue(
            GmailError.http(403, #"{"error":{"status":"PERMISSION_DENIED"}}"#)))
        XCTAssertFalse(ThreadEditRetryPolicy.shouldRequeue(GmailError.noRefreshToken("a@x.com")))
        XCTAssertFalse(ThreadEditRetryPolicy.shouldRequeue(GmailError.historyExpired))
        XCTAssertFalse(ThreadEditRetryPolicy.shouldRequeue(CancellationError()))
    }

    /// Connectivity failures keep their own path (`OfflinePolicy.shouldDefer`
    /// also sets the offline state); this policy must not claim them.
    func testConnectivityFailuresAreNotServerFailures() {
        XCTAssertFalse(ThreadEditRetryPolicy.shouldRequeue(URLError(.notConnectedToInternet)))
        XCTAssertFalse(ThreadEditRetryPolicy.shouldRequeue(URLError(.timedOut)))
    }

    func testFailureKindSeparatesQuotaFromServerErrors() {
        XCTAssertEqual(ThreadEditRetryPolicy.serverFailure(GmailError.http(429, "")), .rateLimited)
        XCTAssertEqual(ThreadEditRetryPolicy.serverFailure(GmailError.http(403, rateLimitBody)),
                       .rateLimited)
        XCTAssertEqual(ThreadEditRetryPolicy.serverFailure(GmailError.http(503, "")), .serverError)
        XCTAssertNil(ThreadEditRetryPolicy.serverFailure(GmailError.http(400, "")))
    }

    /// A queued edit does not replay for ever: after the age limit a server
    /// failure drops it, so a stale edit cannot reach Gmail days later.
    func testQueuedEditExpiresAfterTheAgeLimit() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let limit = ThreadEditRetryPolicy.maxQueuedAge
        XCTAssertEqual(limit, 24 * 60 * 60)
        XCTAssertFalse(ThreadEditRetryPolicy.isExpired(createdAt: now, now: now))
        XCTAssertFalse(ThreadEditRetryPolicy.isExpired(
            createdAt: now.addingTimeInterval(-limit + 1), now: now))
        XCTAssertTrue(ThreadEditRetryPolicy.isExpired(
            createdAt: now.addingTimeInterval(-limit - 1), now: now))
        // A clock that moved back must not expire a fresh row.
        XCTAssertFalse(ThreadEditRetryPolicy.isExpired(
            createdAt: now.addingTimeInterval(600), now: now))
    }

    func testReplayStopsForARateLimitAtOnceAndForRepeatedServerErrors() {
        XCTAssertTrue(ThreadEditRetryPolicy.stopsReplay(after: .rateLimited, failuresSoFar: 1))
        XCTAssertFalse(ThreadEditRetryPolicy.stopsReplay(after: .serverError, failuresSoFar: 1))
        XCTAssertFalse(ThreadEditRetryPolicy.stopsReplay(
            after: .serverError,
            failuresSoFar: ThreadEditRetryPolicy.maxServerFailuresPerPass - 1))
        XCTAssertTrue(ThreadEditRetryPolicy.stopsReplay(
            after: .serverError,
            failuresSoFar: ThreadEditRetryPolicy.maxServerFailuresPerPass))
    }
}
