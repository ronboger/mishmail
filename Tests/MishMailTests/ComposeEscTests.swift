import XCTest

final class ComposeEscTests: XCTestCase {
    func testSettingsAlwaysPassesThrough() {
        XCTAssertEqual(
            ComposeEsc.intent(
                isSettingsWindow: true,
                slashPickerVisible: true,
                commandPaletteOpen: true,
                composeExpanded: true,
                isSplit: true),
            .passThrough)
    }

    func testSlashPickerBeatsSplitAndPalette() {
        XCTAssertEqual(
            ComposeEsc.intent(
                isSettingsWindow: false,
                slashPickerVisible: true,
                commandPaletteOpen: true,
                composeExpanded: true,
                isSplit: true),
            .dismissSlashPicker)
    }

    func testPaletteBeatsSplit() {
        XCTAssertEqual(
            ComposeEsc.intent(
                isSettingsWindow: false,
                slashPickerVisible: false,
                commandPaletteOpen: true,
                composeExpanded: true,
                isSplit: true),
            .closeCommandPalette)
    }

    func testSplitExitBeforeSaveAndClose() {
        XCTAssertEqual(
            ComposeEsc.intent(
                isSettingsWindow: false,
                slashPickerVisible: false,
                commandPaletteOpen: false,
                composeExpanded: true,
                isSplit: true),
            .exitSplit)
    }

    func testExpandedComposeClosesOnEsc() {
        XCTAssertEqual(
            ComposeEsc.intent(
                isSettingsWindow: false,
                slashPickerVisible: false,
                commandPaletteOpen: false,
                composeExpanded: true,
                isSplit: false),
            .saveAndCloseCompose)
    }

    func testMinimizedOrNoComposeFallsThrough() {
        XCTAssertEqual(
            ComposeEsc.intent(
                isSettingsWindow: false,
                slashPickerVisible: false,
                commandPaletteOpen: false,
                composeExpanded: false,
                isSplit: false),
            .fallThrough)
        // isSplit is irrelevant when compose is not expanded.
        XCTAssertEqual(
            ComposeEsc.intent(
                isSettingsWindow: false,
                slashPickerVisible: false,
                commandPaletteOpen: false,
                composeExpanded: false,
                isSplit: true),
            .fallThrough)
    }
}
