import XCTest

final class LLMRetryPolicyTests: XCTestCase {
    func testOnlyTransientStatusesRetry() {
        for status in [408, 409, 429, 500, 502, 503, 504, 529] {
            XCTAssertTrue(LLMRetryPolicy.shouldRetry(status: status), "\(status)")
        }
        for status in [400, 401, 403, 404, 422, 499, 530] {
            XCTAssertFalse(LLMRetryPolicy.shouldRetry(status: status), "\(status)")
        }
    }

    func testTransientURLCodesRetry() {
        XCTAssertTrue(LLMRetryPolicy.shouldRetry(urlError: URLError(.timedOut)))
        XCTAssertTrue(LLMRetryPolicy.shouldRetry(urlError: URLError(.networkConnectionLost)))
        XCTAssertTrue(LLMRetryPolicy.shouldRetry(urlError: URLError(.cannotConnectToHost)))
        XCTAssertFalse(LLMRetryPolicy.shouldRetry(urlError: URLError(.cancelled)))
    }

    func testExponentialDelayHasBoundedJitter() {
        let low = LLMRetryPolicy.delay(attempt: 1, randomUnit: 0)
        let high = LLMRetryPolicy.delay(attempt: 1, randomUnit: 1)
        XCTAssertEqual(low, 0.5, accuracy: 0.0001)
        XCTAssertEqual(high, 1.0, accuracy: 0.0001)
        XCTAssertGreaterThan(high, low)
    }

    func testProviderRetryHeadersOverrideAndCapDelay() {
        XCTAssertEqual(LLMRetryPolicy.delay(attempt: 0, retryAfter: "4", randomUnit: 0), 4)
        XCTAssertEqual(LLMRetryPolicy.delay(attempt: 0, retryAfterMilliseconds: "2500",
                                            randomUnit: 0), 2.5)
        XCTAssertEqual(LLMRetryPolicy.delay(attempt: 0, retryAfter: "90", randomUnit: 0), 30)
    }
}
