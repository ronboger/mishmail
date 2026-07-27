import XCTest

final class AppThemeTests: XCTestCase {
    func testUnknownOrMissingRawFallsBackToSystem() {
        XCTAssertEqual(AppTheme.from(raw: nil), .system)
        XCTAssertEqual(AppTheme.from(raw: "neon"), .system)
        XCTAssertEqual(AppTheme.from(raw: "dark"), .dark)
        XCTAssertEqual(AppTheme.from(raw: "light"), .light)
    }

    func testAppearanceMapping() {
        XCTAssertNil(AppTheme.system.nsAppearance)
        XCTAssertEqual(AppTheme.light.nsAppearance?.name, .aqua)
        XCTAssertEqual(AppTheme.dark.nsAppearance?.name, .darkAqua)
    }
}
