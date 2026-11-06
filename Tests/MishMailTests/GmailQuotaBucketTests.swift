import XCTest

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

    func testDefaultsStayUnderGmailsMinuteLimit() {
        let bucket = GmailQuotaBucket()
        XCTAssertLessThan(bucket.capacity + 60 * bucket.refillPerSecond, 6_000)
    }

    func testBatchAndSingleGetCostsByFormat() {
        for (format, cost) in [("metadata", 20), ("minimal", 20), ("full", 60),
                               ("raw", 60), ("html", 60)] {
            XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/messages/m1", format: format), cost)
            XCTAssertEqual(GmailQuotaBucket.messageGetUnits(format: format), cost)
            XCTAssertEqual(GmailClient.batchGetChunkSize(format: format), GmailQuotaBucket.defaultCapacity / cost)
        }
    }

    func testEndpointCosts() {
        XCTAssertEqual(GmailClient.quotaCost(method: "POST", path: "/labels"), 5)
        XCTAssertEqual(GmailClient.quotaCost(method: "POST", path: "/messages/m1/modify"), 5)
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/threads/t1"), 120)
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/threads/t1", format: "metadata"), 40)
        XCTAssertEqual(GmailClient.quotaCost(method: "POST", path: "/threads/t1/trash"), 20)
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/drafts"), 5)
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/drafts/d1"), 60)
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/drafts/d1", format: "minimal"), 20)
        XCTAssertEqual(GmailClient.quotaCost(method: "PUT", path: "/drafts/d1"), 15)
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/profile"), 1)
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/history"), 2)
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/messages"), 5)
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/messages/m1"), 60)
        XCTAssertEqual(GmailClient.quotaCost(method: "POST", path: "/threads/t1/modify"), 10)
        XCTAssertEqual(GmailClient.quotaCost(method: "POST", path: "/messages/send"), 100)
        XCTAssertEqual(GmailClient.quotaCost(method: "POST", path: "/drafts"), 10)
        XCTAssertEqual(GmailClient.quotaCost(method: "GET", path: "/messages/m1/attachments/a1"), 20)
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
        XCTAssertEqual(bucket.delayBeforeSpending(units: 5, now: t0),
                       GmailQuotaBucket.maxPenalty + 0.025, accuracy: 0.001)
        // Once the clamped penalty ends the bucket works normally again.
        let later = t0.addingTimeInterval(GmailQuotaBucket.maxPenalty + 10)
        XCTAssertEqual(bucket.penaltyRemaining(now: later), 0)
        XCTAssertEqual(bucket.delayBeforeSpending(units: 5, now: later), 0, accuracy: 0.001)
    }

    func testQueuedSpendWaitsForFullRefillBeyondPenaltyCap() {
        var bucket = GmailQuotaBucket()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let delays = (0..<26).map { _ in bucket.delayBeforeSpending(units: 120, now: t0) }
        XCTAssertEqual(delays[25], 3_000.0 / 90, accuracy: 0.001)
    }
}
