import XCTest

final class RemoteFailureKindTests: XCTestCase {

    func testConnectivityFailuresAreOffline() {
        for code: URLError.Code in [.notConnectedToInternet, .timedOut, .networkConnectionLost] {
            XCTAssertEqual(RemoteFailureKind.classify(URLError(code)), .offline, "\(code)")
        }
    }

    func testRejectedSignInNeedsReauth() {
        XCTAssertEqual(RemoteFailureKind.classify(OAuthError.invalidGrant), .reauth)
        XCTAssertEqual(RemoteFailureKind.classify(GmailError.noRefreshToken("a@x.com")), .reauth)
    }

    func testRateLimitAndServerErrorsAreRetryable() {
        XCTAssertEqual(RemoteFailureKind.classify(GmailError.http(429, "")), .retryable)
        XCTAssertEqual(RemoteFailureKind.classify(GmailError.http(500, "")), .retryable)
        XCTAssertEqual(RemoteFailureKind.classify(GmailError.http(503, "backendError")), .retryable)
        XCTAssertEqual(
            RemoteFailureKind.classify(GmailError.http(403, #"{"reason":"userRateLimitExceeded"}"#)),
            .retryable)
        // A 401 that survived the client's own refresh-and-retry is a
        // credential hiccup, not a verdict on the request.
        XCTAssertEqual(RemoteFailureKind.classify(GmailError.http(401, "")), .retryable)
        XCTAssertEqual(RemoteFailureKind.classify(GmailError.http(408, "")), .retryable)
    }

    func testOtherClientErrorsArePermanent() {
        XCTAssertEqual(RemoteFailureKind.classify(GmailError.http(400, "Invalid To header")), .permanent)
        XCTAssertEqual(RemoteFailureKind.classify(GmailError.http(404, "")), .permanent)
        XCTAssertEqual(RemoteFailureKind.classify(GmailError.http(403, "insufficientPermissions")), .permanent)
        XCTAssertEqual(RemoteFailureKind.classify(GmailError.http(413, "")), .permanent)
    }

    /// Anything that is not a clear verdict from Gmail leaves the outcome of
    /// the request unknown — it must be retried (behind the caller's
    /// idempotency check), never reported as a rejection.
    func testUnknownOutcomesAreRetryable() {
        XCTAssertEqual(RemoteFailureKind.classify(CancellationError()), .retryable)
        XCTAssertEqual(RemoteFailureKind.classify(URLError(.cancelled)), .retryable)
        XCTAssertEqual(RemoteFailureKind.classify(URLError(.badServerResponse)), .retryable)
        XCTAssertEqual(RemoteFailureKind.classify(GmailError.keychainUnavailable("a@x.com", -25308)), .retryable)
        XCTAssertEqual(
            RemoteFailureKind.classify(NSError(domain: "decode", code: 1)), .retryable)
    }
}
