import XCTest

final class MessageFetchFailureTests: XCTestCase {
    func testClassify404NotFound() {
        XCTAssertEqual(
            MessageFetchFailureKind.classify(GmailError.http(404, "gone")),
            .notFound)
    }

    func testClassify429And5xxRetryable() {
        XCTAssertEqual(
            MessageFetchFailureKind.classify(GmailError.http(429, "slow")),
            .retryable)
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

    func testClassifyURLErrorRetryable() {
        let err = URLError(.timedOut)
        XCTAssertEqual(MessageFetchFailureKind.classify(err), .retryable)
    }

    func testPartialFetchErrorMessage() {
        let e = GmailError.partialFetch(failedCount: 3)
        XCTAssertTrue(e.localizedDescription.contains("3"))
    }
}
