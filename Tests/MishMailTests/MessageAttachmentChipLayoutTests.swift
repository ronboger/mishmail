import XCTest

final class MessageAttachmentChipLayoutTests: XCTestCase {

    /// Regression: the outer HStack held padding + background while the
    /// Quick Look button wrapped only icon + filename. Clicks on the chip
    /// chrome did nothing; only the text glyphs hit.
    func testPreviewIncludesChipPadding() {
        XCTAssertTrue(MessageAttachmentChipLayout.previewIncludesChipPadding)
        let insets = MessageAttachmentChipLayout.previewHitInsets()
        XCTAssertEqual(insets.leading, MessageAttachmentChipLayout.horizontalPadding)
        XCTAssertEqual(insets.vertical, MessageAttachmentChipLayout.verticalPadding)
        XCTAssertGreaterThan(insets.trailing, 0,
                             "gap before the eye must belong to preview, not dead chrome")
    }

    /// Three sibling buttons cover the chip. No inert outer padding region.
    func testRegionsCoverTheWholeChip() {
        XCTAssertEqual(
            MessageAttachmentChipLayout.regions,
            ["preview", "quickLook", "save"])
        XCTAssertEqual(MessageAttachmentChipLayout.regionSpacing, 0,
                       "spacing between regions was unclickable chrome")
    }

    func testPrimaryClickQuickLooksNotOpens() {
        XCTAssertEqual(MessageAttachmentChipLayout.previewAction, "quickLook")
        XCTAssertEqual(MessageAttachmentChipLayout.quickLookAction, "quickLook")
        XCTAssertNotEqual(MessageAttachmentChipLayout.previewAction, "open")
    }

    func testSaveStaysADistinctTrailingAction() {
        XCTAssertEqual(MessageAttachmentChipLayout.saveAction, "save")
        XCTAssertTrue(MessageAttachmentChipLayout.regions.contains("save"))
        let insets = MessageAttachmentChipLayout.saveHitInsets()
        XCTAssertEqual(insets.trailing, MessageAttachmentChipLayout.horizontalPadding)
        XCTAssertEqual(insets.vertical, MessageAttachmentChipLayout.verticalPadding)
    }

    func testCornerRadiusMatchesChipChrome() {
        XCTAssertEqual(MessageAttachmentChipLayout.cornerRadius, 8)
    }

    func testRegionsFillChipHeight() {
        XCTAssertTrue(MessageAttachmentChipLayout.regionsFillChipHeight)
        XCTAssertEqual(
            MessageAttachmentChipLayout.chipMinHeight,
            20 + MessageAttachmentChipLayout.verticalPadding * 2)
        XCTAssertGreaterThan(MessageAttachmentChipLayout.chipMinHeight, 20)
    }
}
