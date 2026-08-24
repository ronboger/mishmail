import XCTest

final class ReadingPaneSpaceScrollTests: XCTestCase {
    func testPageDownAdvancesByViewportMinusOverlap() {
        let t = ReadingPaneSpaceScroll.pageTarget(
            current: 0, viewportHeight: 1000, contentHeight: 5000, up: false)
        XCTAssertEqual(t, 850)
    }

    func testPageDownClampsToBottom() {
        let t = ReadingPaneSpaceScroll.pageTarget(
            current: 3900, viewportHeight: 1000, contentHeight: 5000, up: false)
        XCTAssertEqual(t, 4000)
    }

    func testPageUpClampsToTop() {
        let t = ReadingPaneSpaceScroll.pageTarget(
            current: 300, viewportHeight: 1000, contentHeight: 5000, up: true)
        XCTAssertEqual(t, 0)
    }

    func testAtBottomReturnsNil() {
        XCTAssertNil(ReadingPaneSpaceScroll.pageTarget(
            current: 4000, viewportHeight: 1000, contentHeight: 5000, up: false))
    }

    func testAtTopPageUpReturnsNil() {
        XCTAssertNil(ReadingPaneSpaceScroll.pageTarget(
            current: 0, viewportHeight: 1000, contentHeight: 5000, up: true))
    }

    func testShortContentReturnsNil() {
        XCTAssertNil(ReadingPaneSpaceScroll.pageTarget(
            current: 0, viewportHeight: 1000, contentHeight: 800, up: false))
    }

    func testLineDownAdvancesByLineStep() {
        let t = ReadingPaneSpaceScroll.lineTarget(
            current: 0, viewportHeight: 1000, contentHeight: 5000, up: false)
        XCTAssertEqual(t, ReadingPaneSpaceScroll.lineStep)
    }

    func testLineDownClampsToBottom() {
        let t = ReadingPaneSpaceScroll.lineTarget(
            current: 3990, viewportHeight: 1000, contentHeight: 5000, up: false)
        XCTAssertEqual(t, 4000)
    }

    func testLineUpClampsToTop() {
        let t = ReadingPaneSpaceScroll.lineTarget(
            current: 20, viewportHeight: 1000, contentHeight: 5000, up: true)
        XCTAssertEqual(t, 0)
    }

    func testLineAtBottomReturnsNil() {
        XCTAssertNil(ReadingPaneSpaceScroll.lineTarget(
            current: 4000, viewportHeight: 1000, contentHeight: 5000, up: false))
    }

    func testLineShortContentReturnsNil() {
        XCTAssertNil(ReadingPaneSpaceScroll.lineTarget(
            current: 0, viewportHeight: 1000, contentHeight: 800, up: false))
    }

    func testOffsetTargetRejectsNonPositiveStep() {
        XCTAssertNil(ReadingPaneSpaceScroll.offsetTarget(
            current: 0, viewportHeight: 1000, contentHeight: 5000,
            up: false, step: 0))
        XCTAssertNil(ReadingPaneSpaceScroll.offsetTarget(
            current: 0, viewportHeight: 1000, contentHeight: 5000,
            up: false, step: -10))
    }
}
