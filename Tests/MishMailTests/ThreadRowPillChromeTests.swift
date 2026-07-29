import XCTest

final class ThreadRowPillChromeTests: XCTestCase {
    func testFocusedUsesSelectionChrome() {
        XCTAssertEqual(ThreadRowPillChrome.forFocused(true), .onSelection)
        XCTAssertEqual(ThreadRowPillChrome.forFocused(false), .softTint)
    }

    func testSelectionChromeIsLightOnSolidTint() {
        let chrome = ThreadRowPillChrome.onSelection
        XCTAssertTrue(chrome.usesLightForeground)
        // Strong enough to read on system blue list selection; soft tint
        // wash (0.16) is the bug this replaces.
        XCTAssertGreaterThan(chrome.fillOpacity, 0.5)
        XCTAssertLessThanOrEqual(chrome.fillOpacity, 1.0)
    }

    func testSoftChromeKeepsTintedTextAndWash() {
        let chrome = ThreadRowPillChrome.softTint
        XCTAssertFalse(chrome.usesLightForeground)
        XCTAssertLessThan(chrome.fillOpacity, 0.3)
        XCTAssertGreaterThan(chrome.fillOpacity, 0)
    }

    func testSelectionFillIsStrongerThanSoft() {
        XCTAssertGreaterThan(
            ThreadRowPillChrome.onSelection.fillOpacity,
            ThreadRowPillChrome.softTint.fillOpacity)
    }
}
