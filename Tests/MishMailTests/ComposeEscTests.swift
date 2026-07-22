import XCTest

final class ComposeEscTests: XCTestCase {
    private func intent(
        isSettingsWindow: Bool = false,
        slashPickerVisible: Bool = false,
        commandPaletteOpen: Bool = false,
        searchActive: Bool = false,
        composeExpanded: Bool = false,
        isSplit: Bool = false
    ) -> ComposeEscIntent {
        ComposeEsc.intent(
            isSettingsWindow: isSettingsWindow,
            slashPickerVisible: slashPickerVisible,
            commandPaletteOpen: commandPaletteOpen,
            searchActive: searchActive,
            composeExpanded: composeExpanded,
            isSplit: isSplit)
    }

    func testSettingsAlwaysPassesThrough() {
        XCTAssertEqual(
            intent(
                isSettingsWindow: true,
                slashPickerVisible: true,
                commandPaletteOpen: true,
                searchActive: true,
                composeExpanded: true,
                isSplit: true),
            .passThrough)
    }

    func testSlashPickerBeatsSplitPaletteAndSearch() {
        XCTAssertEqual(
            intent(
                slashPickerVisible: true,
                commandPaletteOpen: true,
                searchActive: true,
                composeExpanded: true,
                isSplit: true),
            .dismissSlashPicker)
    }

    func testPaletteBeatsSplitAndSearch() {
        XCTAssertEqual(
            intent(
                commandPaletteOpen: true,
                searchActive: true,
                composeExpanded: true,
                isSplit: true),
            .closeCommandPalette)
    }

    func testSearchFocusBeatsSaveAndCloseAndSplit() {
        // Floating/inline draft + sidebar `/` must not close the draft.
        XCTAssertEqual(
            intent(searchActive: true, composeExpanded: true, isSplit: false),
            .dismissSearchFocus)
        // Split has no search chrome in practice; still prefer search if set.
        XCTAssertEqual(
            intent(searchActive: true, composeExpanded: true, isSplit: true),
            .dismissSearchFocus)
        // Search alone (no compose) still blurs via the same path.
        XCTAssertEqual(
            intent(searchActive: true),
            .dismissSearchFocus)
    }

    func testSplitExitBeforeSaveAndClose() {
        XCTAssertEqual(
            intent(composeExpanded: true, isSplit: true),
            .exitSplit)
    }

    func testExpandedComposeClosesOnEsc() {
        XCTAssertEqual(
            intent(composeExpanded: true, isSplit: false),
            .saveAndCloseCompose)
    }

    func testMinimizedOrNoComposeFallsThrough() {
        XCTAssertEqual(intent(), .fallThrough)
        // isSplit is irrelevant when compose is not expanded.
        XCTAssertEqual(intent(isSplit: true), .fallThrough)
    }
}
