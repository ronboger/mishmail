import XCTest

/// Retry delays for a failed message get. A dropped connection recovers in
/// well under a second; a rate limit does not — Gmail keeps answering 403
/// until its window reopens, so those retries wait for the time Gmail
/// names, or whole seconds when it names none.
final class GmailRetryBackoffTests: XCTestCase {
    func testTransientBackoffStaysSubSecond() {
        XCTAssertEqual(GmailRetryBackoff.delay(attempt: 0, kind: .retryable), 0.2, accuracy: 0.001)
        XCTAssertEqual(GmailRetryBackoff.delay(attempt: 1, kind: .retryable), 0.4, accuracy: 0.001)
    }

    func testRateLimitBackoffIsWholeSecondsAndGrows() {
        XCTAssertEqual(GmailRetryBackoff.delay(attempt: 0, kind: .rateLimited), 2.0, accuracy: 0.001)
        XCTAssertEqual(GmailRetryBackoff.delay(attempt: 1, kind: .rateLimited), 4.0, accuracy: 0.001)
        XCTAssertEqual(GmailRetryBackoff.delay(attempt: 2, kind: .rateLimited), 8.0, accuracy: 0.001)
    }

    func testRateLimitBackoffHonorsGmailsRetryAfterWhenLonger() {
        XCTAssertEqual(GmailRetryBackoff.delay(attempt: 0, kind: .rateLimited, retryAfter: 9.4),
                       9.4, accuracy: 0.001)
        // Never shorter than the schedule: a "retry after" already in the
        // past still gets a real pause.
        XCTAssertEqual(GmailRetryBackoff.delay(attempt: 0, kind: .rateLimited, retryAfter: 0),
                       2.0, accuracy: 0.001)
    }

    func testRateLimitedFailuresRetryButFatalOnesDoNot() {
        XCTAssertTrue(MessageFetchFailureKind.rateLimited.isRetryable)
        XCTAssertTrue(MessageFetchFailureKind.retryable.isRetryable)
        XCTAssertFalse(MessageFetchFailureKind.fatal.isRetryable)
        XCTAssertFalse(MessageFetchFailureKind.notFound.isRetryable)
    }
}
