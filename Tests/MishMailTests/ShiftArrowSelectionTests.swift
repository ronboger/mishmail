import XCTest

/// Shift+↑/↓ keyboard range select: anchor sticks where the gesture started,
/// the range follows focus, reversing shrinks, and unrelated checks survive.
final class ShiftArrowSelectionTests: XCTestCase {
    private let order = ["a", "b", "c", "d", "e"]

    func testFirstShiftDownChecksCurrentAndNextRow() {
        let r = ShiftArrowSelection.extend(
            order: order, checked: [], anchor: nil, focus: "b", delta: 1)
        XCTAssertEqual(r, .init(checked: ["b", "c"], focusId: "c", anchorId: "b"))
    }

    func testFirstShiftUpChecksCurrentAndPreviousRow() {
        let r = ShiftArrowSelection.extend(
            order: order, checked: [], anchor: nil, focus: "c", delta: -1)
        XCTAssertEqual(r, .init(checked: ["b", "c"], focusId: "b", anchorId: "c"))
    }

    func testRepeatedShiftDownGrowsRangeFromAnchor() {
        var r = ShiftArrowSelection.extend(
            order: order, checked: [], anchor: nil, focus: "a", delta: 1)!
        r = ShiftArrowSelection.extend(
            order: order, checked: r.checked, anchor: r.anchorId,
            focus: r.focusId, delta: 1)!
        XCTAssertEqual(r, .init(checked: ["a", "b", "c"], focusId: "c", anchorId: "a"))
    }

    func testReversingDirectionShrinksRange() {
        var r = ShiftArrowSelection.extend(
            order: order, checked: [], anchor: nil, focus: "a", delta: 1)!
        r = ShiftArrowSelection.extend(
            order: order, checked: r.checked, anchor: r.anchorId,
            focus: r.focusId, delta: 1)!
        r = ShiftArrowSelection.extend(
            order: order, checked: r.checked, anchor: r.anchorId,
            focus: r.focusId, delta: -1)!
        XCTAssertEqual(r, .init(checked: ["a", "b"], focusId: "b", anchorId: "a"))
    }

    func testShrinkingPastAnchorExtendsOtherDirection() {
        // Anchor c, extend down to d, then up twice: c..d → c → b..c.
        var r = ShiftArrowSelection.extend(
            order: order, checked: [], anchor: nil, focus: "c", delta: 1)!
        r = ShiftArrowSelection.extend(
            order: order, checked: r.checked, anchor: r.anchorId,
            focus: r.focusId, delta: -1)!
        XCTAssertEqual(r.checked, ["c"])
        r = ShiftArrowSelection.extend(
            order: order, checked: r.checked, anchor: r.anchorId,
            focus: r.focusId, delta: -1)!
        XCTAssertEqual(r, .init(checked: ["b", "c"], focusId: "b", anchorId: "c"))
    }

    func testChecksOutsideTheSweptRangeSurvive() {
        let r = ShiftArrowSelection.extend(
            order: order, checked: ["e"], anchor: nil, focus: "a", delta: 1)
        XCTAssertEqual(r?.checked, ["a", "b", "e"])
    }

    func testBoundaryPressStillChecksFocusedRow() {
        let r = ShiftArrowSelection.extend(
            order: order, checked: [], anchor: nil, focus: "e", delta: 1)
        XCTAssertEqual(r, .init(checked: ["e"], focusId: "e", anchorId: "e"))
    }

    func testNoFocusLandsLikePlainArrowAndChecks() {
        let down = ShiftArrowSelection.extend(
            order: order, checked: [], anchor: nil, focus: nil, delta: 1)
        XCTAssertEqual(down, .init(checked: ["a"], focusId: "a", anchorId: "a"))
        let up = ShiftArrowSelection.extend(
            order: order, checked: [], anchor: nil, focus: nil, delta: -1)
        XCTAssertEqual(up, .init(checked: ["a"], focusId: "a", anchorId: "a"))
    }

    func testStaleAnchorFallsBackToFocus() {
        let r = ShiftArrowSelection.extend(
            order: order, checked: [], anchor: "gone", focus: "b", delta: 1)
        XCTAssertEqual(r?.anchorId, "b")
        XCTAssertEqual(r?.checked, ["b", "c"])
    }

    func testEmptyOrderReturnsNil() {
        XCTAssertNil(ShiftArrowSelection.extend(
            order: [], checked: [], anchor: nil, focus: nil, delta: 1))
    }
}
