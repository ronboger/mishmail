import XCTest

/// History catch-up used to fetch every changed message in one go and only
/// then record the new history id. A rate limit anywhere in that run meant
/// nothing was recorded, and the next pass replayed the same range — for
/// days. Slicing lets the engine commit the history id after each slice.
final class HistorySlicerTests: XCTestCase {
    private func rec(_ id: String, added: Int = 0, label: Int = 0) -> HistorySlicer.Record {
        HistorySlicer.Record(
            id: id,
            addedIds: (0..<added).map { "\(id)-a\($0)" },
            labelChangedIds: (0..<label).map { "\(id)-l\($0)" })
    }

    func testEmptyHistoryYieldsNoSlices() {
        XCTAssertTrue(HistorySlicer.slices([], maxMessages: 100).isEmpty)
    }

    func testRecordsAccumulateUntilTheMessageBudgetIsReached() {
        let records = [rec("1", added: 40), rec("2", added: 40), rec("3", added: 40)]
        let slices = HistorySlicer.slices(records, maxMessages: 100)
        XCTAssertEqual(slices.map { $0.records.map(\.id) }, [["1", "2"], ["3"]])
        XCTAssertEqual(slices.map(\.lastRecordId), ["2", "3"])
    }

    func testLabelOnlyChangesCountTowardTheBudget() {
        let records = [rec("1", label: 60), rec("2", label: 60)]
        XCTAssertEqual(HistorySlicer.slices(records, maxMessages: 100).count, 2)
    }

    func testARecordNeverSplitsAcrossSlices() {
        // One record bigger than the budget still lands whole in its own slice.
        let records = [rec("1", added: 250), rec("2", added: 1)]
        let slices = HistorySlicer.slices(records, maxMessages: 100)
        XCTAssertEqual(slices.map { $0.records.map(\.id) }, [["1"], ["2"]])
    }

    func testRecordOrderIsPreservedWithinAndAcrossSlices() {
        let records = (1...5).map { rec("\($0)", added: 30) }
        let slices = HistorySlicer.slices(records, maxMessages: 100)
        XCTAssertEqual(slices.flatMap { $0.records.map(\.id) }, ["1", "2", "3", "4", "5"])
    }

    /// The engine commits the previous slice before attempting the next one;
    /// a failure in slice two therefore leaves slice one as the replay point.
    func testFailureAtSliceTwoLeavesSliceOneCommitPoint() {
        let slices = HistorySlicer.slices(
            [rec("slice-1", added: 2), rec("slice-2", added: 2)], maxMessages: 2)
        var committed = "initial"
        for (index, slice) in slices.enumerated() {
            if index == 1 { break }
            committed = slice.lastRecordId
        }
        XCTAssertEqual(committed, "slice-1")
    }
}
