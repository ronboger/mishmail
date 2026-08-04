import XCTest

final class StarNavAnchorTests: XCTestCase {
    // MARK: - anchor computation

    func testMidListNeighbors() {
        let order = ["a", "b", "c", "d"]
        let anchor = StarNavAnchor.anchor(
            displayOrder: order, focusId: "b", starredIds: ["b"])
        XCTAssertEqual(anchor?.fromId, "b")
        XCTAssertEqual(anchor?.prevId, "a")
        XCTAssertEqual(anchor?.nextId, "c")
    }

    func testTopOfListPrevIsNil() {
        let anchor = StarNavAnchor.anchor(
            displayOrder: ["a", "b", "c"], focusId: "a", starredIds: ["a"])
        XCTAssertEqual(anchor?.fromId, "a")
        XCTAssertNil(anchor?.prevId)
        XCTAssertEqual(anchor?.nextId, "b")
    }

    func testBottomOfListNextIsNil() {
        let anchor = StarNavAnchor.anchor(
            displayOrder: ["a", "b", "c"], focusId: "c", starredIds: ["c"])
        XCTAssertEqual(anchor?.fromId, "c")
        XCTAssertEqual(anchor?.prevId, "b")
        XCTAssertNil(anchor?.nextId)
    }

    func testSkipsAdjacentStarredIds() {
        // Bulk-star b+c+d while focused on c: neighbors skip the whole block.
        let order = ["a", "b", "c", "d", "e"]
        let starred: Set<String> = ["b", "c", "d"]
        let anchor = StarNavAnchor.anchor(
            displayOrder: order, focusId: "c", starredIds: starred)
        XCTAssertEqual(anchor?.fromId, "c")
        XCTAssertEqual(anchor?.prevId, "a")
        XCTAssertEqual(anchor?.nextId, "e")
    }

    func testOnlyStarredSurvivorsYieldNilNeighbors() {
        let anchor = StarNavAnchor.anchor(
            displayOrder: ["a", "b", "c"], focusId: "b",
            starredIds: ["a", "b", "c"])
        XCTAssertEqual(anchor?.fromId, "b")
        XCTAssertNil(anchor?.prevId)
        XCTAssertNil(anchor?.nextId)
    }

    func testMissingFocusReturnsNil() {
        XCTAssertNil(StarNavAnchor.anchor(
            displayOrder: ["a", "b"], focusId: "zz", starredIds: ["zz"]))
        XCTAssertNil(StarNavAnchor.anchor(
            displayOrder: [], focusId: "a", starredIds: ["a"]))
    }

    // MARK: - applies / consume decision

    func testAppliesForSingleStepWithPresentTarget() {
        XCTAssertTrue(StarNavAnchor.applies(
            currentSelectedId: "b", anchorFromId: "b",
            delta: 1, targetPresent: true))
        XCTAssertTrue(StarNavAnchor.applies(
            currentSelectedId: "b", anchorFromId: "b",
            delta: -1, targetPresent: true))
    }

    func testAppliesRejectsWrongSelectedId() {
        XCTAssertFalse(StarNavAnchor.applies(
            currentSelectedId: "x", anchorFromId: "b",
            delta: 1, targetPresent: true))
        XCTAssertFalse(StarNavAnchor.applies(
            currentSelectedId: nil, anchorFromId: "b",
            delta: 1, targetPresent: true))
    }

    func testAppliesRejectsMultiStepDelta() {
        XCTAssertFalse(StarNavAnchor.applies(
            currentSelectedId: "b", anchorFromId: "b",
            delta: 2, targetPresent: true))
        XCTAssertFalse(StarNavAnchor.applies(
            currentSelectedId: "b", anchorFromId: "b",
            delta: -3, targetPresent: true))
        XCTAssertFalse(StarNavAnchor.applies(
            currentSelectedId: "b", anchorFromId: "b",
            delta: 0, targetPresent: true))
    }

    func testAppliesRejectsMissingTarget() {
        XCTAssertFalse(StarNavAnchor.applies(
            currentSelectedId: "b", anchorFromId: "b",
            delta: 1, targetPresent: false))
    }

    func testTargetIdByDelta() {
        let anchor = StarNavAnchor.Anchor(
            fromId: "b", nextId: "c", prevId: "a")
        XCTAssertEqual(StarNavAnchor.targetId(in: anchor, delta: 1), "c")
        XCTAssertEqual(StarNavAnchor.targetId(in: anchor, delta: -1), "a")
        XCTAssertNil(StarNavAnchor.targetId(in: anchor, delta: 0))
        XCTAssertEqual(StarNavAnchor.targetId(in: anchor, delta: 2), "c")
        XCTAssertEqual(StarNavAnchor.targetId(in: anchor, delta: -5), "a")
    }

    func testTargetIdNilSides() {
        let top = StarNavAnchor.Anchor(fromId: "a", nextId: "b", prevId: nil)
        XCTAssertNil(StarNavAnchor.targetId(in: top, delta: -1))
        let bottom = StarNavAnchor.Anchor(fromId: "z", nextId: nil, prevId: "y")
        XCTAssertNil(StarNavAnchor.targetId(in: bottom, delta: 1))
    }
}
