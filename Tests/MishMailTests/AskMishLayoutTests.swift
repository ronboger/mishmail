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
}
