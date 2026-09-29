import XCTest

/// Gmail's quota error names the moment the window reopens:
/// "User-rate limit exceeded.  Retry after 2026-09-16T03:57:19.386Z".
/// Retrying earlier than that only spends attempts.
final class GmailRateLimitTests: XCTestCase {
    private let body = """
    {"error":{"code":403,"message":"User-rate limit exceeded.  Retry after 2026-09-16T03:57:19.386Z",\
    "errors":[{"domain":"usageLimits","reason":"userRateLimitExceeded"}]}}
    """

    func testRetryAfterParsesTheTimestampRelativeToNow() {
        let now = ISO8601DateFormatter().date(from: "2026-09-16T03:57:10Z")!
        let delay = GmailRateLimit.retryAfter(body: body, now: now)
        XCTAssertEqual(delay!, 9.386, accuracy: 0.01)
    }

    func testRetryAfterInThePastIsZero() {
        let now = ISO8601DateFormatter().date(from: "2026-09-16T04:00:00Z")!
        XCTAssertEqual(GmailRateLimit.retryAfter(body: body, now: now)!, 0, accuracy: 0.001)
    }

    func testRetryAfterIsNilWithoutATimestamp() {
        XCTAssertNil(GmailRateLimit.retryAfter(body: #"{"error":{"code":403,"message":"Rate Limit Exceeded"}}"#,
                                               now: Date()))
    }

    func testRetryAfterIsCappedSoABadClockCannotStallSync() {
        let now = ISO8601DateFormatter().date(from: "2026-09-16T00:00:00Z")!
        XCTAssertEqual(GmailRateLimit.retryAfter(body: body, now: now)!, GmailRateLimit.maxWait, accuracy: 0.001)
    }
}
