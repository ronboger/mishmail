import XCTest

final class AskMishLayoutTests: XCTestCase {

    func testPanelWidthClampsToBounds() {
        XCTAssertEqual(AskMishLayout.panelWidth(hostWidth: 500), 320)   // floor
        XCTAssertEqual(AskMishLayout.panelWidth(hostWidth: 2000), 480)  // ceiling
        XCTAssertEqual(AskMishLayout.panelWidth(hostWidth: 1250), 400)  // 0.32 in range
    }

    /// An unmeasured host (first frame) must not collapse the panel below the
    /// floor, and must not report a negative width.
    func testPanelWidthOnUnmeasuredHost() {
        XCTAssertEqual(AskMishLayout.panelWidth(hostWidth: 0), 320)
        XCTAssertEqual(AskMishLayout.panelWidth(hostWidth: -100), 320)
    }

    func testPanelHiddenOnNarrowHosts() {
        XCTAssertFalse(AskMishLayout.showsPanel(hostWidth: 800, enabled: true))
        XCTAssertTrue(AskMishLayout.showsPanel(hostWidth: 1200, enabled: true))
        XCTAssertFalse(AskMishLayout.showsPanel(hostWidth: 1200, enabled: false))
    }

    /// The host floor is inclusive, and an unmeasured host keeps the panel
    /// hidden instead of flashing it at the floor width.
    func testPanelVisibilityAtBoundaries() {
        XCTAssertTrue(AskMishLayout.showsPanel(hostWidth: AskMishLayout.minHostWidth,
                                               enabled: true))
        XCTAssertFalse(AskMishLayout.showsPanel(
            hostWidth: AskMishLayout.minHostWidth - 1, enabled: true))
        XCTAssertFalse(AskMishLayout.showsPanel(hostWidth: 0, enabled: true))
    }

    /// The mailbox keeps at least the panel floor for itself, so opening the
    /// panel never squeezes the list out of the window.
    func testMailboxKeepsRoomForItself() {
        let hostWidth: CGFloat = 1200
        let panel = AskMishLayout.panelWidth(hostWidth: hostWidth)
        XCTAssertGreaterThanOrEqual(hostWidth - panel, AskMishLayout.minPanelWidth)
    }


    // MARK: - Transcript near-bottom

    func testNearBottomWithinSlack() {
        XCTAssertTrue(AskMishLayout.isNearBottom(.init(offsetY: 560, containerHeight: 400,
                                                        contentHeight: 1_000)))
        XCTAssertFalse(AskMishLayout.isNearBottom(.init(offsetY: 100, containerHeight: 400,
                                                         contentHeight: 1_000)))
        // Short content is always at the bottom.
        XCTAssertTrue(AskMishLayout.isNearBottom(.init(offsetY: 0, containerHeight: 400,
                                                        contentHeight: 200)))
    }

    func testContentGrowthAloneDoesNotChangeNearBottom() {
        let old = AskMishLayout.ScrollMetrics(offsetY: 600, containerHeight: 400,
                                              contentHeight: 1_000)
        let grown = AskMishLayout.ScrollMetrics(offsetY: 600, containerHeight: 400,
                                                contentHeight: 1_400)
        XCTAssertNil(AskMishLayout.nearBottomAfterScroll(from: old, to: grown))
    }

    func testWheelScrollUpAndBackDownUpdatesNearBottom() {
        let bottom = AskMishLayout.ScrollMetrics(offsetY: 600, containerHeight: 400,
                                                 contentHeight: 1_000)
        let up = AskMishLayout.ScrollMetrics(offsetY: 200, containerHeight: 400,
                                             contentHeight: 1_000)
        XCTAssertEqual(AskMishLayout.nearBottomAfterScroll(from: bottom, to: up), false)
        XCTAssertEqual(AskMishLayout.nearBottomAfterScroll(from: up, to: bottom), true)
    }
}
