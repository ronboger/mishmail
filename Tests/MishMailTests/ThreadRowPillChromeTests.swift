import XCTest

final class ThreadRowPillChromeTests: XCTestCase {
    func testFocusedUsesSelectionChrome() {
        XCTAssertEqual(ThreadRowPillChrome.forFocused(true), .onSelection)
        XCTAssertEqual(ThreadRowPillChrome.forFocused(false), .softTint)
    }

    func testSelectionFillIsStrongerThanSoft() {
        XCTAssertGreaterThan(
            ThreadRowPillChrome.onSelection.fillOpacity,
            ThreadRowPillChrome.softTint.fillOpacity)
        XCTAssertGreaterThan(ThreadRowPillChrome.onSelection.fillOpacity, 0.5)
        XCTAssertLessThan(ThreadRowPillChrome.softTint.fillOpacity, 0.3)
    }

    // MARK: - Luminance / pale-tint foreground

    func testDarkTintsPreferWhiteTitleOnSelection() {
        // Notion palette red / blue — white text is correct.
        XCTAssertEqual(ThreadRowPillChrome.selectionUsesLightForeground(hex: "#EB5757"), true)
        XCTAssertEqual(ThreadRowPillChrome.selectionUsesLightForeground(hex: "#2D9CDB"), true)
        XCTAssertEqual(ThreadRowPillChrome.selectionUsesLightForeground(hex: "#27AE60"), true)
        // Near-black
        XCTAssertTrue(ThreadRowPillChrome.selectionUsesLightForeground(r: 0.1, g: 0.1, b: 0.1))
    }

    func testPaleTintsPreferDarkTitleOnSelection() {
        // Gmail-style pale yellow / light gray — white-on-cream fails contrast.
        XCTAssertEqual(ThreadRowPillChrome.selectionUsesLightForeground(hex: "#FAD165"), false)
        XCTAssertEqual(ThreadRowPillChrome.selectionUsesLightForeground(hex: "#C2C2C2"), false)
        XCTAssertEqual(ThreadRowPillChrome.selectionUsesLightForeground(hex: "#FFFFFF"), false)
        // Notion yellow (#DFAB01) is a mid tone and should keep white text.
        XCTAssertEqual(ThreadRowPillChrome.selectionUsesLightForeground(hex: "#DFAB01"), true)
        let pale = ThreadRowPillChrome.relativeLuminance(r: 0.98, g: 0.82, b: 0.40)
        let mid = ThreadRowPillChrome.relativeLuminance(r: 0.92, g: 0.60, b: 0.29)
        XCTAssertGreaterThan(pale, ThreadRowPillChrome.lightForegroundMaxLuminance)
        XCTAssertLessThan(mid, ThreadRowPillChrome.lightForegroundMaxLuminance)
    }

    func testHexParsingAndNilFallback() {
        XCTAssertNil(ThreadRowPillChrome.selectionUsesLightForeground(hex: nil))
        XCTAssertNil(ThreadRowPillChrome.selectionUsesLightForeground(hex: "not-a-color"))
        XCTAssertNil(ThreadRowPillChrome.selectionUsesLightForeground(hex: "#RGB"))
        XCTAssertNotNil(ThreadRowPillChrome.parseHexRGB("#EB5757"))
        XCTAssertNotNil(ThreadRowPillChrome.parseHexRGB("EB5757"))
        let rgb = ThreadRowPillChrome.parseHexRGB("#FFFFFF")!
        XCTAssertEqual(rgb.r, 1, accuracy: 0.001)
        XCTAssertEqual(rgb.g, 1, accuracy: 0.001)
        XCTAssertEqual(rgb.b, 1, accuracy: 0.001)
    }

    func testRelativeLuminanceWhiteAndBlack() {
        XCTAssertEqual(ThreadRowPillChrome.relativeLuminance(r: 1, g: 1, b: 1), 1, accuracy: 0.001)
        XCTAssertEqual(ThreadRowPillChrome.relativeLuminance(r: 0, g: 0, b: 0), 0, accuracy: 0.001)
    }
}
