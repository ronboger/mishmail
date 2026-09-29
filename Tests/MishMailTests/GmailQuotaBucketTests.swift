import XCTest

/// Gmail allows 250 quota units per user per second. A pass that fires four
/// 50-message batches (250 units each) inside two seconds trips a 403
/// rateLimitExceeded and the connection is dropped. The bucket paces
/// requests so a pass stays under that ceiling.
final class GmailQuotaBucketTests: XCTestCase {
    func testFullBucketSpendsWithoutDelay() {
        var bucket = GmailQuotaBucket(capacity: 250, refillPerSecond: 250)
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(bucket.delayBeforeSpending(units: 250, now: t0), 0, accuracy: 0.001)
    }

    func testSecondFullBatchWaitsOneSecond() {
        var bucket = GmailQuotaBucket(capacity: 250, refillPerSecond: 250)
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = bucket.delayBeforeSpending(units: 250, now: t0)
        XCTAssertEqual(bucket.delayBeforeSpending(units: 250, now: t0), 1.0, accuracy: 0.001)
    }

    func testRefillAfterOneSecondClearsTheWait() {
        var bucket = GmailQuotaBucket(capacity: 250, refillPerSecond: 250)
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = bucket.delayBeforeSpending(units: 250, now: t0)
        XCTAssertEqual(bucket.delayBeforeSpending(units: 250, now: t0.addingTimeInterval(1)),
                       0, accuracy: 0.001)
    }

    func testSmallSpendsAccumulate() {
        var bucket = GmailQuotaBucket(capacity: 250, refillPerSecond: 250)
        let t0 = Date(timeIntervalSince1970: 1_000)
        for _ in 0..<50 { _ = bucket.delayBeforeSpending(units: 5, now: t0) }  // 250 units
        XCTAssertEqual(bucket.delayBeforeSpending(units: 5, now: t0), 0.02, accuracy: 0.001)
    }

    func testDelayedSpendIsChargedAtTheWaitedTime() {
        // Ask for 250 twice at t0: the second must wait 1s. A third ask at
        // t0 must wait a further second (2s), not reuse the first wait.
        var bucket = GmailQuotaBucket(capacity: 250, refillPerSecond: 250)
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = bucket.delayBeforeSpending(units: 250, now: t0)
        _ = bucket.delayBeforeSpending(units: 250, now: t0)
        XCTAssertEqual(bucket.delayBeforeSpending(units: 250, now: t0), 2.0, accuracy: 0.001)
    }

    /// Gmail enforces 250 units/s as a moving average and a 50-message
    /// batch spends 250 at once. Refilling below the ceiling, with smaller
    /// batches, keeps a full pass under the average.
    func testDefaultsStayUnderGmailsMovingAverage() {
        let bucket = GmailQuotaBucket()
        XCTAssertEqual(bucket.capacity, 250)
        XCTAssertEqual(bucket.refillPerSecond, 200)
        XCTAssertLessThanOrEqual(GmailQuotaBucket.units(forMessageGets: GmailClient.batchGetChunkSize), 125)
    }

    func testMessageGetCosts() {
        XCTAssertEqual(GmailQuotaBucket.units(forMessageGets: 1), 5)
        XCTAssertEqual(GmailQuotaBucket.units(forMessageGets: 50), 250)
    }
}
