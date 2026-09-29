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
        XCTAssertEqual(bucket.capacity, 125)
        XCTAssertEqual(bucket.refillPerSecond, 200)
        XCTAssertLessThanOrEqual(GmailQuotaBucket.units(forMessageGets: GmailClient.batchGetChunkSize), 125)
    }

    func testMessageGetCosts() {
        XCTAssertEqual(GmailQuotaBucket.units(forMessageGets: 1), 5)
        XCTAssertEqual(GmailQuotaBucket.units(forMessageGets: 50), 250)
    }

    func testEndpointCosts() {
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/profile"), 1)
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/history"), 2)
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/messages"), 5)
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/messages/m1"), 5)
        XCTAssertEqual(GmailClient.quotaCost(method: "POST", path: "/threads/t1/modify"), 10)
        XCTAssertEqual(GmailClient.quotaCost(method: "POST", path: "/messages/send"), 100)
        XCTAssertEqual(GmailClient.quotaCost(method: "POST", path: "/drafts"), 10)
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/messages/m1/attachments/a1"), 5)
    }

    func testPenaltyBlocksAllCallersUntilItExpires() {
        var bucket = GmailQuotaBucket(capacity: 125, refillPerSecond: 250)
        let t0 = Date(timeIntervalSince1970: 1_000)
        bucket.block(until: t0.addingTimeInterval(4))
        XCTAssertEqual(bucket.penaltyRemaining(now: t0), 4, accuracy: 0.001)
        XCTAssertEqual(bucket.delayBeforeSpending(units: 5, now: t0), 4.02, accuracy: 0.001)
        XCTAssertEqual(bucket.penaltyRemaining(now: t0.addingTimeInterval(4)), 0, accuracy: 0.001)
    }

    /// Callers parked behind one penalty used to get the same wake time and
    /// no reservation, so they all fired together and tripped the limit
    /// again. Each reservation now lands one refill after the previous one.
    func testCallersParkedBehindAPenaltyAreReleasedInSequence() {
        var bucket = GmailQuotaBucket(capacity: 125, refillPerSecond: 200)
        let t0 = Date(timeIntervalSince1970: 1_000)
        bucket.block(until: t0.addingTimeInterval(4))
        let delays = (0..<3).map { _ in bucket.delayBeforeSpending(units: 50, now: t0) }
        XCTAssertEqual(delays[0], 4.25, accuracy: 0.001)
        XCTAssertEqual(delays[1], 4.5, accuracy: 0.001)
        XCTAssertEqual(delays[2], 4.75, accuracy: 0.001)
    }

    /// The client parks until the penalty ends, then reserves. The bucket
    /// restarts empty, so waking callers still queue behind each other.
    func testReservingAfterThePenaltyStartsFromAnEmptyBucket() {
        var bucket = GmailQuotaBucket(capacity: 125, refillPerSecond: 200)
        let t0 = Date(timeIntervalSince1970: 1_000)
        bucket.block(until: t0.addingTimeInterval(2))
        let wake = t0.addingTimeInterval(2)
        XCTAssertEqual(bucket.penaltyRemaining(now: wake), 0)
        XCTAssertEqual(bucket.delayBeforeSpending(units: 50, now: wake), 0.25, accuracy: 0.001)
        XCTAssertEqual(bucket.delayBeforeSpending(units: 50, now: wake), 0.5, accuracy: 0.001)
    }

    /// A clock that jumped (or a far-future stamp) must not park the account
    /// past the longest wait Gmail can ask for.
    func testFarFuturePenaltyIsClamped() {
        var bucket = GmailQuotaBucket(capacity: 125, refillPerSecond: 200)
        let t0 = Date(timeIntervalSince1970: 1_000)
        bucket.block(until: t0.addingTimeInterval(3_600))
        XCTAssertEqual(bucket.penaltyRemaining(now: t0), GmailQuotaBucket.maxPenalty, accuracy: 0.001)
        XCTAssertLessThanOrEqual(bucket.delayBeforeSpending(units: 5, now: t0), GmailRateLimit.maxWait)
        // Once the clamped penalty ends the bucket works normally again.
        let later = t0.addingTimeInterval(GmailQuotaBucket.maxPenalty + 10)
        XCTAssertEqual(bucket.penaltyRemaining(now: later), 0)
        XCTAssertEqual(bucket.delayBeforeSpending(units: 5, now: later), 0, accuracy: 0.001)
    }

    func testSingleDelayIsCappedAtMaxWait() {
        var bucket = GmailQuotaBucket(capacity: 10, refillPerSecond: 1)
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(bucket.delayBeforeSpending(units: 10_000, now: t0),
                       GmailRateLimit.maxWait, accuracy: 0.001)
    }
}
