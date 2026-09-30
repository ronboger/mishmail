import XCTest

/// BoundedLanes — the per-account concurrency cap for bulk thread edits.
final class BoundedLanesTests: XCTestCase {

    /// Records start order and the peak number in flight, overall and per lane.
    private actor Probe {
        private(set) var started: [String] = []
        private(set) var finished: [String] = []
        private var inFlight: [String: Int] = [:]
        private(set) var peakPerLane: [String: Int] = [:]
        private var total = 0
        private(set) var peakTotal = 0

        func begin(_ id: String, lane: String) {
            started.append(id)
            inFlight[lane, default: 0] += 1
            peakPerLane[lane] = max(peakPerLane[lane] ?? 0, inFlight[lane]!)
            total += 1
            peakTotal = max(peakTotal, total)
        }

        func end(_ id: String, lane: String) {
            finished.append(id)
            inFlight[lane, default: 0] -= 1
            total -= 1
        }
    }

    private struct Item: Sendable {
        var id: String
        var lane: String
    }

    private func work(_ probe: Probe) -> @Sendable (Item) async -> Void {
        { item in
            await probe.begin(item.id, lane: item.lane)
            try? await Task.sleep(nanoseconds: 5_000_000)
            await probe.end(item.id, lane: item.lane)
        }
    }

    func testEmptyIsNoOp() async {
        let probe = Probe()
        await BoundedLanes.run([Item](), maxInFlight: 4, lane: { $0.lane }, body: work(probe))
        let started = await probe.started
        XCTAssertEqual(started, [])
    }

    func testRunsEveryItemAndCapsEachLane() async {
        let probe = Probe()
        let items = (0..<12).map { Item(id: "a\($0)", lane: "a") }
            + (0..<6).map { Item(id: "b\($0)", lane: "b") }
        await BoundedLanes.run(items, maxInFlight: 3, lane: { $0.lane }, body: work(probe))
        let finished = await probe.finished
        let peaks = await probe.peakPerLane
        XCTAssertEqual(Set(finished), Set(items.map(\.id)))
        XCTAssertEqual(finished.count, items.count)
        XCTAssertLessThanOrEqual(peaks["a"] ?? 0, 3)
        XCTAssertLessThanOrEqual(peaks["b"] ?? 0, 3)
    }

    func testLanesDoNotShareTheCap() async {
        // Two lanes of 2 with cap 2: all four can overlap.
        let probe = Probe()
        let gate = Gate(expected: 4)
        let items = [Item(id: "a0", lane: "a"), Item(id: "a1", lane: "a"),
                     Item(id: "b0", lane: "b"), Item(id: "b1", lane: "b")]
        await BoundedLanes.run(items, maxInFlight: 2, lane: { $0.lane }) { item in
            await probe.begin(item.id, lane: item.lane)
            await gate.arriveAndWait()
            await probe.end(item.id, lane: item.lane)
        }
        let peak = await probe.peakTotal
        XCTAssertEqual(peak, 4)
    }

    func testCapOfOneRunsALaneInInputOrder() async {
        let probe = Probe()
        let items = (0..<5).map { Item(id: "a\($0)", lane: "a") }
        await BoundedLanes.run(items, maxInFlight: 1, lane: { $0.lane }, body: work(probe))
        let started = await probe.started
        let finished = await probe.finished
        XCTAssertEqual(started, items.map(\.id))
        XCTAssertEqual(finished, items.map(\.id))
    }

    func testNonPositiveCapStillRuns() async {
        let probe = Probe()
        let items = (0..<3).map { Item(id: "a\($0)", lane: "a") }
        await BoundedLanes.run(items, maxInFlight: 0, lane: { $0.lane }, body: work(probe))
        let finished = await probe.finished
        let peaks = await probe.peakPerLane
        XCTAssertEqual(finished.count, 3)
        XCTAssertEqual(peaks["a"], 1)
    }

    /// Releases every waiter once `expected` have arrived; proves they were
    /// all in flight together (a cap below `expected` would deadlock, so the
    /// test would time out rather than pass).
    private actor Gate {
        private let expected: Int
        private var arrived = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(expected: Int) { self.expected = expected }

        func arriveAndWait() async {
            arrived += 1
            if arrived >= expected {
                waiters.forEach { $0.resume() }
                waiters.removeAll()
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}
