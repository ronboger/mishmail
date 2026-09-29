import XCTest

final class SendAsRefreshPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testDueWhenNeverFetched() {
        XCTAssertTrue(SendAsRefreshPolicy.isDue(lastSuccess: nil, lastAttempt: nil, now: now))
    }

    /// The regression: a 60 s poll tick must not re-fetch aliases every minute.
    func testNotDueRightAfterSuccess() {
        let t = now.addingTimeInterval(-60)
        XCTAssertFalse(SendAsRefreshPolicy.isDue(lastSuccess: t, lastAttempt: t, now: now))
    }

    func testDueAfterSuccessInterval() {
        let t = now.addingTimeInterval(-SendAsRefreshPolicy.successInterval)
        XCTAssertTrue(SendAsRefreshPolicy.isDue(lastSuccess: t, lastAttempt: t, now: now))
    }

    /// A failed fetch (offline launch) retries after the short back-off, not
    /// the full success interval, and not every poll tick either.
    func testFailureBacksOffShortly() {
        let failed = now.addingTimeInterval(-60)
        XCTAssertFalse(SendAsRefreshPolicy.isDue(lastSuccess: nil, lastAttempt: failed, now: now))
        let older = now.addingTimeInterval(-SendAsRefreshPolicy.failureRetryInterval)
        XCTAssertTrue(SendAsRefreshPolicy.isDue(lastSuccess: nil, lastAttempt: older, now: now))
    }

    /// Stale success + recent failure: wait out the failure back-off.
    func testStaleSuccessWithRecentFailureWaits() {
        let success = now.addingTimeInterval(-2 * SendAsRefreshPolicy.successInterval)
        let failed = now.addingTimeInterval(-30)
        XCTAssertFalse(SendAsRefreshPolicy.isDue(lastSuccess: success, lastAttempt: failed, now: now))
    }

    /// Clock moved backwards: stamps in the future must not block forever.
    func testFutureStampsCountAsExpired() {
        let future = now.addingTimeInterval(3_600)
        XCTAssertTrue(SendAsRefreshPolicy.isDue(lastSuccess: future, lastAttempt: future, now: now))
    }
}
