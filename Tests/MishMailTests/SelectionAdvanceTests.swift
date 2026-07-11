import XCTest

final class SelectionAdvanceTests: XCTestCase {
    func testMiddleRowAdvancesDown() {
        XCTAssertEqual(SelectionAdvance.neighborId(in: ["a", "b", "c"], removing: "b"), "c")
    }

    func testFirstRowAdvancesDown() {
        XCTAssertEqual(SelectionAdvance.neighborId(in: ["a", "b", "c"], removing: "a"), "b")
    }

    func testLastRowFallsBackUp() {
        XCTAssertEqual(SelectionAdvance.neighborId(in: ["a", "b", "c"], removing: "c"), "b")
    }

    func testOnlyRowReturnsNil() {
        XCTAssertNil(SelectionAdvance.neighborId(in: ["a"], removing: "a"))
    }

    func testMissingIdReturnsNil() {
        XCTAssertNil(SelectionAdvance.neighborId(in: ["a", "b"], removing: "zz"))
        XCTAssertNil(SelectionAdvance.neighborId(in: [], removing: "a"))
    }

    // MARK: - Multi-remove

    func testMultiRemoveAdvancesPastBlock() {
        // Focus on b; remove b and c → land on d (first survivor below).
        XCTAssertEqual(
            SelectionAdvance.neighborId(in: ["a", "b", "c", "d"],
                                        removing: ["b", "c"], focus: "b"),
            "d")
    }

    func testMultiRemoveAtEndFallsBackUp() {
        XCTAssertEqual(
            SelectionAdvance.neighborId(in: ["a", "b", "c"],
                                        removing: ["b", "c"], focus: "c"),
            "a")
    }

    func testMultiRemoveKeepsFocusWhenNotRemoved() {
        XCTAssertEqual(
            SelectionAdvance.neighborId(in: ["a", "b", "c"],
                                        removing: ["a"], focus: "b"),
            "b")
    }

    func testMultiRemoveAllReturnsNil() {
        XCTAssertNil(
            SelectionAdvance.neighborId(in: ["a", "b"],
                                        removing: ["a", "b"], focus: "a"))
    }

    func testMultiRemoveWithNoFocusPicksFirstSurvivor() {
        XCTAssertEqual(
            SelectionAdvance.neighborId(in: ["a", "b", "c"],
                                        removing: ["a"], focus: nil),
            "b")
    }

    // MARK: - Range

    func testRangeIdsForwardAndBackward() {
        XCTAssertEqual(SelectionAdvance.rangeIds(in: ["a", "b", "c", "d"], from: "b", to: "d"),
                       ["b", "c", "d"])
        XCTAssertEqual(SelectionAdvance.rangeIds(in: ["a", "b", "c", "d"], from: "d", to: "b"),
                       ["b", "c", "d"])
        XCTAssertEqual(SelectionAdvance.rangeIds(in: ["a", "b", "c"], from: "b", to: "b"),
                       ["b"])
    }

    func testRangeIdsMissingReturnsNil() {
        XCTAssertNil(SelectionAdvance.rangeIds(in: ["a", "b"], from: "a", to: "zz"))
        XCTAssertNil(SelectionAdvance.rangeIds(in: [], from: "a", to: "b"))
    }

    // MARK: - Optimistic leave-list vs stickiness

    /// Regression: under is:unread, opening a thread pins it via keepIds.
    /// Trash must still remove the row so auto-advance can land on the next
    /// conversation — keepIds (and multi-select checks) drop with the row.
    func testLeaveListDropsKeepIdAndChecked() {
        let leave = ThreadListOptimistic.plan(leavesCurrentList: true)
        XCTAssertEqual(leave.effect, .remove)
        XCTAssertEqual(leave.sideEffects, .onRemove)
        XCTAssertTrue(leave.sideEffects.dropKeepId)
        XCTAssertTrue(leave.sideEffects.dropChecked)

        let stay = ThreadListOptimistic.plan(leavesCurrentList: false)
        XCTAssertEqual(stay.effect, .updateInPlace)
        XCTAssertEqual(stay.sideEffects, .none)
    }
}
