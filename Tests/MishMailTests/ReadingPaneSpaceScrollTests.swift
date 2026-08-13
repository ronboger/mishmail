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
}
