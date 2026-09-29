import XCTest

/// Sync / AI-sort progress used to publish `syncStatus` once per report.
/// `StatusThrottle` drops repeats and caps deliveries at ~4 Hz while always
/// delivering the newest value of a burst.
final class StatusThrottleTests: XCTestCase {
    func testFirstChangeDeliversImmediately() {
        var t = StatusThrottle(interval: 0.25)
        XCTAssertEqual(t.submit("a", now: 0), .deliver("a"))
    }

    func testUnchangedValueIsDropped() {
        var t = StatusThrottle(interval: 0.25, shown: "Syncing…")
        XCTAssertEqual(t.submit("Syncing…", now: 0), .drop)
        XCTAssertEqual(t.submit("x", now: 0), .deliver("x"))
        XCTAssertEqual(t.submit("x", now: 1), .drop)
    }

    func testBurstSchedulesOneTrailingFlushWithNewestValue() {
        var t = StatusThrottle(interval: 0.25)
        XCTAssertEqual(t.submit("1", now: 0), .deliver("1"))
        XCTAssertEqual(t.submit("2", now: 0.125), .scheduleFlush(after: 0.125))
        XCTAssertEqual(t.submit("3", now: 0.15), .drop)
        XCTAssertEqual(t.submit("4", now: 0.2), .drop)
        XCTAssertEqual(t.flush(now: 0.25), "4")
        XCTAssertNil(t.pending)
        XCTAssertFalse(t.flushScheduled)
    }

    func testChangeBackToShownValueCancelsPending() {
        var t = StatusThrottle(interval: 0.25)
        _ = t.submit("a", now: 0)
        _ = t.submit("b", now: 0.1)
        XCTAssertEqual(t.submit("a", now: 0.2), .drop)
        XCTAssertNil(t.flush(now: 0.25))
    }

    func testAfterQuietIntervalDeliversAtLeadingEdgeAgain() {
        var t = StatusThrottle(interval: 0.25)
        _ = t.submit("a", now: 0)
        XCTAssertEqual(t.submit("b", now: 0.3), .deliver("b"))
    }

    func testWhileFlushScheduledNewValuesWaitForTheFlush() {
        var t = StatusThrottle(interval: 0.25)
        _ = t.submit("a", now: 0)
        _ = t.submit("b", now: 0.1)          // schedules flush
        // Past the interval but the flush has not run yet: fold into it
        // rather than deliver out of order.
        XCTAssertEqual(t.submit("c", now: 0.3), .drop)
        XCTAssertEqual(t.flush(now: 0.31), "c")
    }

    func testRateNeverExceedsOneDeliveryPerInterval() {
        var t = StatusThrottle(interval: 0.25)
        var deliveries: [TimeInterval] = []
        var flushAt: TimeInterval?
        var now: TimeInterval = 0
        var i = 0
        while now < 2 {
            if let at = flushAt, now >= at {
                if t.flush(now: now) != nil { deliveries.append(now) }
                flushAt = nil
            }
            switch t.submit("\(i)", now: now) {
            case .deliver: deliveries.append(now)
            case .scheduleFlush(let wait): flushAt = now + wait
            case .drop: break
            }
            i += 1
            now += 0.01
        }
        for (a, b) in zip(deliveries, deliveries.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 0.25 - 1e-9)
        }
        XCTAssertGreaterThanOrEqual(deliveries.count, 7)
    }

    // MARK: - Sink

    @MainActor
    func testSinkDeliversNewestAndStopsAfterClose() async {
        let received = Received()
        let sink = ThrottledStatusSink(interval: 0.05) { value in
            received.values.append(value)
        }
        sink.submit("1")
        sink.submit("2")
        sink.submit("3")
        for _ in 0..<200 where received.values.last != "3" {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(received.values, ["1", "3"])

        sink.submit("4")
        sink.close()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(received.values, ["1", "3"], "close() must drop hops already queued")
    }

    @MainActor
    private final class Received {
        var values: [String] = []
    }
}
