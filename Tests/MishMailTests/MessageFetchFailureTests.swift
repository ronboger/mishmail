import XCTest

final class MessageFetchFailureTests: XCTestCase {
    func testClassify404NotFound() {
        XCTAssertEqual(
            MessageFetchFailureKind.classify(GmailError.http(404, "gone")),
            .notFound)
    }

    func testClassify5xxRetryable() {
        XCTAssertEqual(
            MessageFetchFailureKind.classify(GmailError.http(503, "down")),
            .retryable)
        XCTAssertEqual(
            MessageFetchFailureKind.classify(GmailError.http(500, "err")),
            .retryable)
    }

    func testClassify403Fatal() {
        XCTAssertEqual(
            MessageFetchFailureKind.classify(GmailError.http(403, "denied")),
            .fatal)
    }

    /// Gmail reports "too many quota units this second" as 403, not 429.
    /// Treating it as fatal aborted the whole history batch every pass and
    /// the sync never advanced.
    func testClassify403RateLimitIsRateLimited() {
        let userLimit = """
        {"error":{"code":403,"message":"User-rate limit exceeded.  Retry after 2026-09-14T08:13:18.000Z",\
        "errors":[{"domain":"usageLimits","reason":"userRateLimitExceeded"}]}}
        """
        XCTAssertEqual(
            MessageFetchFailureKind.classify(GmailError.http(403, userLimit)),
            .rateLimited)
        let projectLimit = """
        {"error":{"code":403,"errors":[{"domain":"usageLimits","reason":"rateLimitExceeded"}]}}
        """
        XCTAssertEqual(
            MessageFetchFailureKind.classify(GmailError.http(403, projectLimit)),
            .rateLimited)
    }

    func testClassify429IsRateLimited() {
        XCTAssertEqual(
            MessageFetchFailureKind.classify(GmailError.http(429, "slow")),
            .rateLimited)
    }

    func testClassifyURLErrorRetryable() {
        let err = URLError(.timedOut)
        XCTAssertEqual(MessageFetchFailureKind.classify(err), .retryable)
    }

    func testPartialFetchErrorMessage() {
        let e = GmailError.partialFetch(failedCount: 3)
        XCTAssertTrue(e.localizedDescription.contains("3"))
    }
}
