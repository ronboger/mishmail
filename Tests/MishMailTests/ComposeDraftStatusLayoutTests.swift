import XCTest

final class ComposeDraftStatusLayoutTests: XCTestCase {

    /// Reserved slot must be sized to a label at least as long as every
    /// painted status — otherwise idle → "Draft saved" (or failed) still
    /// inserts width into the compose footer and nudges the card chrome.
    func testWidthSizerIsLongestVisibleLabel() {
        XCTAssertTrue(ComposeDraftStatusLayout.sizerIsLongestLabel())
        XCTAssertEqual(
            ComposeDraftStatusLayout.widthSizerLabel,
            ComposeDraftStatusLayout.failedLabel)
    }

    func testVisibleLabelsCoverEveryNonIdleStatus() {
        let labels = Set(ComposeDraftStatusLayout.visibleLabels)
        XCTAssertEqual(labels, [
            ComposeDraftStatusLayout.savingLabel,
            ComposeDraftStatusLayout.savedLabel,
            ComposeDraftStatusLayout.failedLabel,
            ComposeDraftStatusLayout.savedOfflineLabel,
        ])
        // Idle must not paint a string into the slot.
        XCTAssertFalse(labels.contains(""))
    }

    /// Footer status row matches the Send control height so status paint
    /// never changes the HStack's vertical size.
    func testRowHeightMatchesSendControl() {
        XCTAssertEqual(ComposeDraftStatusLayout.rowHeight, 22)
        XCTAssertGreaterThan(ComposeDraftStatusLayout.fontSize, 0)
        XCTAssertLessThanOrEqual(
            ComposeDraftStatusLayout.fontSize,
            ComposeDraftStatusLayout.rowHeight)
    }

    func testStatusCopyIsStable() {
        // Accessibility ids and UI copy depend on these exact strings.
        XCTAssertEqual(ComposeDraftStatusLayout.savingLabel, "Saving…")
        XCTAssertEqual(ComposeDraftStatusLayout.savedLabel, "Draft saved")
        XCTAssertEqual(ComposeDraftStatusLayout.failedLabel, "Draft not saved")
    }
}
