import XCTest

/// SyncEngine.withBoundedConcurrency — control-flow helper used by
/// incremental sync to download messages with the same concurrency cap as
/// fetchAll, while keeping result handling serial.
final class BoundedConcurrencyTests: XCTestCase {

    /// Thread-safe counters for concurrent fetch instrumentation.
    private actor Counter {
        private(set) var values: [String] = []
        private(set) var inFlight = 0
        private(set) var peak = 0

        func record(_ id: String) {
            values.append(id)
            inFlight += 1
            peak = max(peak, inFlight)
        }

        func endFlight() {
            inFlight -= 1
        }

        func snapshot() -> (values: [String], peak: Int) {
            (values, peak)
        }
    }

    func testEmptyIdsIsNoOp() async throws {
        var handled = 0
        await SyncEngine.withBoundedConcurrency(
            ids: [String](),
            concurrency: 8,
            fetch: { (_: String) async -> Int? in
                XCTFail("fetch should not run for empty ids")
                return 1
            },
            onValue: { (_: Int) async in handled += 1 }
        )
        XCTAssertEqual(handled, 0)
    }

    func testAllIdsFetchedAndNonNilHandled() async throws {
        let ids = (0..<20).map(String.init)
        let counter = Counter()
        var handled: [Int] = []

        let fetch: @Sendable (String) async -> Int? = { id in
            await counter.record(id)
            await counter.endFlight()
            return Int(id)
        }

        await SyncEngine.withBoundedConcurrency(
            ids: ids,
            concurrency: 4,
            fetch: fetch,
            onValue: { value in handled.append(value) }
        )

        let fetched = await counter.snapshot().values
        XCTAssertEqual(Set(fetched), Set(ids), "every id must be requested")
        XCTAssertEqual(Set(handled), Set(0..<20), "every successful fetch is handled")
        XCTAssertEqual(handled.count, 20)
    }

    func testNilFetchResultsAreSkipped() async throws {
        var handled: [String] = []
        let fetch: @Sendable (String) async -> String? = { id in
            // Fail "b" and "d"; succeed "a" and "c".
            (id == "a" || id == "c") ? id : nil
        }
        await SyncEngine.withBoundedConcurrency(
            ids: ["a", "b", "c", "d"],
            concurrency: 2,
            fetch: fetch,
            onValue: { value in handled.append(value) }
        )
        XCTAssertEqual(Set(handled), ["a", "c"])
    }

    func testPeakConcurrencyIsBounded() async throws {
        let ids = (0..<40).map(String.init)
        let concurrency = 8
        let counter = Counter()

        let fetch: @Sendable (String) async -> Int? = { id in
            await counter.record(id)
            // Yield so overlapping tasks actually pile up.
            try? await Task.sleep(nanoseconds: 5_000_000)
            await counter.endFlight()
            return 1
        }

        await SyncEngine.withBoundedConcurrency(
            ids: ids,
            concurrency: concurrency,
            fetch: fetch,
            onValue: { (_: Int) async in }
        )

        let peak = await counter.snapshot().peak
        XCTAssertLessThanOrEqual(peak, concurrency,
                                 "peak in-flight fetches must not exceed concurrency cap")
        XCTAssertGreaterThan(peak, 1,
                             "expected some overlap; test timing may need a longer sleep")
    }

    func testOnValueRunsSerially() async throws {
        // If onValue were invoked concurrently, overlapping critical sections
        // would be visible via a re-entrancy counter.
        var depth = 0
        var maxDepth = 0
        var count = 0

        let fetch: @Sendable (Int) async -> Int? = { i in
            try? await Task.sleep(nanoseconds: 1_000_000)
            return i
        }

        await SyncEngine.withBoundedConcurrency(
            ids: Array(0..<30),
            concurrency: 8,
            fetch: fetch,
            onValue: { (_: Int) async in
                depth += 1
                maxDepth = max(maxDepth, depth)
                count += 1
                // Brief stall; concurrent onValue would push depth > 1.
                try? await Task.sleep(nanoseconds: 500_000)
                depth -= 1
            }
        )

        XCTAssertEqual(count, 30)
        XCTAssertEqual(maxDepth, 1, "onValue must run serially (one at a time)")
    }
}
