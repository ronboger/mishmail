import XCTest

final class ComposeFooterLayoutTests: XCTestCase {

    /// Regression: status between trash and Send left a large idle hole in
    /// the footer. Status must lead; trash stays adjacent to Send.
    func testTrashAdjacentToSendNotSeparatedByStatus() {
        XCTAssertEqual(
            ComposeFooterLayout.rightClusterOrder,
            ["status", "trash", "send"])
        XCTAssertTrue(ComposeFooterLayout.trashAdjacentToSend())
        XCTAssertNotEqual(
            ComposeFooterLayout.rightClusterOrder,
            ["trash", "status", "send"],
            "status-between trash and Send is the screenshot bug")
    }

    /// When the card is narrower than left+right ideals, left tools shrink
    /// first so draft status / trash / Send stay fully visible.
    func testLeftToolsYieldWidthToRightCluster() {
        let card: CGFloat = 400
        let right: CGFloat = 220
        XCTAssertEqual(
            ComposeFooterLayout.leftToolsMaxWidth(cardInnerWidth: card,
                                                  rightClusterWidth: right),
            180)
        XCTAssertTrue(
            ComposeFooterLayout.rightClusterFits(cardInnerWidth: card,
                                                 rightClusterWidth: right))
    }

    /// Pathologically narrow card: left goes to zero; right still reports
    /// its ideal (SwiftUI keeps fixedSize; card may clip only if host is
    /// smaller than the right cluster alone — placement clamps the host).
    func testLeftToolsZeroWhenRightClaimsAllWidth() {
        XCTAssertEqual(
            ComposeFooterLayout.leftToolsMaxWidth(cardInnerWidth: 180,
                                                  rightClusterWidth: 220),
            0)
        XCTAssertFalse(
            ComposeFooterLayout.rightClusterFits(cardInnerWidth: 180,
                                                 rightClusterWidth: 220))
    }

    func testNeverNegativeLeftWidth() {
        XCTAssertEqual(
            ComposeFooterLayout.leftToolsMaxWidth(cardInnerWidth: 100,
                                                  rightClusterWidth: 500),
            0)
        XCTAssertEqual(
            ComposeFooterLayout.leftToolsMaxWidth(cardInnerWidth: 500,
                                                  rightClusterWidth: -10),
            500)
    }

    /// Typical floating card (620 − 28pt padding) must fit a reserved status
    /// + Send right cluster so the screenshot clip cannot recur at default
    /// width.
    func testDefaultFloatingInnerWidthFitsRightCluster() {
        let cardInner = ComposePlacement.preferredFloatingWidth - 28
        // status sizer (~95+8) + trash (~24) + Send+chevron (~80) + gaps ≈ 220
        // (status is left of trash so trash/Send stay adjacent)
        let rightCluster: CGFloat = 220
        XCTAssertTrue(
            ComposeFooterLayout.rightClusterFits(cardInnerWidth: cardInner,
                                                 rightClusterWidth: rightCluster))
        XCTAssertGreaterThan(
            ComposeFooterLayout.leftToolsMaxWidth(cardInnerWidth: cardInner,
                                                  rightClusterWidth: rightCluster),
            200)
    }
}
