import XCTest

final class QuickLookKeyOwnershipTests: XCTestCase {
    func testPanelWindowClaimsKeysEvenIfNotMarkedVisible() {
        XCTAssertTrue(QuickLookKeyOwnership.claimsKeys(
            eventWindowIsPreviewPanel: true, previewPanelVisible: false))
    }

    func testVisiblePanelClaimsKeysWhenEventIsOnMainWindow() {
        // The reported Esc-closes-thread bug: local monitor sees the main
        // window as event.window while Quick Look is still on screen.
        XCTAssertTrue(QuickLookKeyOwnership.claimsKeys(
            eventWindowIsPreviewPanel: false, previewPanelVisible: true))
    }

    func testBothTrueStillClaimsKeys() {
        XCTAssertTrue(QuickLookKeyOwnership.claimsKeys(
            eventWindowIsPreviewPanel: true, previewPanelVisible: true))
    }

    func testMailboxKeepsEscWhenPreviewIsGone() {
        XCTAssertFalse(QuickLookKeyOwnership.claimsKeys(
            eventWindowIsPreviewPanel: false, previewPanelVisible: false))
    }
}
