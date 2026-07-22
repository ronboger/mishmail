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

    // MARK: - Detail open policy

    /// Regression: trash/archive auto-advance must open the neighbor
    /// immediately — the j/k debounce left the reading pane blank and rebuilt
    /// it from scratch (the "delete feels slow" lag).
    func testAdvanceAfterRemovalOpensImmediately() {
        XCTAssertTrue(DetailOpenPolicy.opensImmediately(
            openedThreadId: "b", listedIds: ["a", "c"]))
    }

    func testBrowsingStillListedKeepsDebounce() {
        XCTAssertFalse(DetailOpenPolicy.opensImmediately(
            openedThreadId: "b", listedIds: ["a", "b", "c"]))
    }

    func testNoOpenPaneKeepsDebounce() {
        XCTAssertFalse(DetailOpenPolicy.opensImmediately(
            openedThreadId: nil, listedIds: ["a"]))
    }

    func testSettleWindowIsLongerThanKeyRepeat() {
        // Key-repeat is ~30–50 ms; settle must outlast a stretched main-thread
        // gap so intermediate opens do not fire while holding ↓.
        XCTAssertGreaterThanOrEqual(DetailOpenPolicy.settleNanoseconds, 100_000_000)
        XCTAssertLessThanOrEqual(DetailOpenPolicy.settleNanoseconds, 250_000_000)
    }

    // MARK: - Thread list navigation (focus only)

    func testMoveDownFromNilSelectsFirst() {
        let order = ["a", "b", "c"]
        let map = ThreadListNavigation.indexMap(for: order)
        XCTAssertEqual(
            ThreadListNavigation.move(selected: nil, delta: 1, order: order, indexById: map),
            "a")
    }

    func testMoveUpFromNilSelectsFirst() {
        let order = ["a", "b", "c"]
        XCTAssertEqual(
            ThreadListNavigation.move(selected: nil, delta: -1, order: order),
            "a")
    }

    func testMoveClampsAtEnds() {
        let order = ["a", "b", "c"]
        let map = ThreadListNavigation.indexMap(for: order)
        XCTAssertEqual(
            ThreadListNavigation.move(selected: "c", delta: 1, order: order, indexById: map),
            "c")
        XCTAssertEqual(
            ThreadListNavigation.move(selected: "a", delta: -1, order: order, indexById: map),
            "a")
    }

    func testMoveUsesIndexMapWithoutLinearScan() {
        let order = (0..<500).map(String.init)
        let map = ThreadListNavigation.indexMap(for: order)
        XCTAssertEqual(map["250"], 250)
        XCTAssertEqual(
            ThreadListNavigation.move(selected: "250", delta: 1, order: order, indexById: map),
            "251")
        XCTAssertEqual(
            ThreadListNavigation.move(selected: "250", delta: -3, order: order, indexById: map),
            "247")
    }

    func testMoveEmptyOrderReturnsNil() {
        XCTAssertNil(ThreadListNavigation.move(selected: "a", delta: 1, order: []))
    }

    func testMoveMissingSelectionTreatsAsBeforeFirstOnDown() {
        let order = ["a", "b", "c"]
        XCTAssertEqual(
            ThreadListNavigation.move(selected: "zz", delta: 1, order: order),
            "a")
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
