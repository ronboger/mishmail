import XCTest

final class ComposeKeyOwnershipTests: XCTestCase {

    func testExpandedComposeClaimsTyping() {
        XCTAssertTrue(ComposeKeyOwnership.claimsTyping(
            hasRequest: true, minimized: false, finishing: false))
        XCTAssertFalse(ComposeKeyOwnership.allowsMailboxKeys(
            hasRequest: true, minimized: false, finishing: false))
    }

    func testMinimizedYieldsMailboxKeys() {
        XCTAssertFalse(ComposeKeyOwnership.claimsTyping(
            hasRequest: true, minimized: true, finishing: false))
        XCTAssertTrue(ComposeKeyOwnership.allowsMailboxKeys(
            hasRequest: true, minimized: true, finishing: false))
    }

    /// After Send, the card stays mounted briefly while persist finishes —
    /// `g i` must reach goTo, not type into the body or no-op.
    func testFinishingYieldsMailboxKeys() {
        XCTAssertFalse(ComposeKeyOwnership.claimsTyping(
            hasRequest: true, minimized: false, finishing: true))
        XCTAssertTrue(ComposeKeyOwnership.allowsMailboxKeys(
            hasRequest: true, minimized: false, finishing: true))
    }

    func testNoComposeAllowsMailboxKeys() {
        XCTAssertFalse(ComposeKeyOwnership.claimsTyping(
            hasRequest: false, minimized: false, finishing: false))
        XCTAssertTrue(ComposeKeyOwnership.allowsMailboxKeys(
            hasRequest: false, minimized: false, finishing: false))
    }

    func testFinishingEvenWhenMinimizedStillYields() {
        // Both flags true is unusual but must not claim typing.
        XCTAssertFalse(ComposeKeyOwnership.claimsTyping(
            hasRequest: true, minimized: true, finishing: true))
    }

    /// Post-Send `e` must not wait on AppKit resigning the body: a lagging
    /// re-focus leaves isEditing true while composeFinishing is set.
    func testFinishingBypassesTextFocusGate() {
        XCTAssertFalse(ComposeKeyOwnership.textFocusBlocksMailboxKeys(
            finishing: true))
        XCTAssertTrue(ComposeKeyOwnership.textFocusBlocksMailboxKeys(
            finishing: false))
    }

    /// Expanded typing still requires the text-focus gate (otherwise j/k
    /// would fire mid-sentence).
    func testExpandedStillBlockedByTextFocusPolicy() {
        XCTAssertTrue(ComposeKeyOwnership.claimsTyping(
            hasRequest: true, minimized: false, finishing: false))
        XCTAssertTrue(ComposeKeyOwnership.textFocusBlocksMailboxKeys(
            finishing: false))
    }
}
