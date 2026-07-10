import XCTest

/// Harness unit tests — ring buffer + measure wrappers. No DB/network.
final class PerfMetricsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PerfMetrics.resetSamples()
    }

    func testMeasureRecordsSample() {
        let value = PerfMetrics.measure(.searchContacts, meta: "qLen=2") {
            42
        }
        XCTAssertEqual(value, 42)
        let samples = PerfMetrics.recentSamples()
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].event, "search.contacts")
        XCTAssertEqual(samples[0].meta, "qLen=2")
        XCTAssertGreaterThanOrEqual(samples[0].ms, 0)
    }

    func testBeginEndRecordsSample() {
        let interval = PerfMetrics.begin(.reloadCounts, meta: "view")
        interval.end(extraMeta: "n=10")
        let samples = PerfMetrics.recentSamples()
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].event, "reload.counts")
        XCTAssertTrue(samples[0].meta.contains("view"))
        XCTAssertTrue(samples[0].meta.contains("n=10"))
    }

    func testRingCapsAtCapacity() {
        for i in 0..<80 {
            PerfMetrics.measure(.syncFlush, meta: "i=\(i)") { () }
        }
        let samples = PerfMetrics.recentSamples()
        XCTAssertEqual(samples.count, 64)
        // Newest last; oldest of the kept window is i=16.
        XCTAssertEqual(samples.first?.meta, "i=16")
        XCTAssertEqual(samples.last?.meta, "i=79")
    }

    func testMeasureAsync() async {
        let n = await PerfMetrics.measureAsync(.searchPreview, meta: "qLen=3") {
            try? await Task.sleep(nanoseconds: 1_000_000)
            return 7
        }
        XCTAssertEqual(n, 7)
        let samples = PerfMetrics.recentSamples()
        XCTAssertEqual(samples.last?.event, "search.preview")
    }
}
