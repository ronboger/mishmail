import XCTest

final class ComposeToolbarVisibilityTests: XCTestCase {

    func testEmptyShowsEverything() {
        for item in ComposeToolbarItem.allCases {
            XCTAssertTrue(ComposeToolbarVisibility.isVisible(item, hiddenRaw: ""))
            XCTAssertTrue(ComposeToolbarVisibility.isVisible(item, hidden: []))
        }
    }

    func testHideMathOnly() {
        let raw = ComposeToolbarVisibility.setting(.math, hidden: true, in: "")
        XCTAssertEqual(raw, "math")
        XCTAssertFalse(ComposeToolbarVisibility.isVisible(.math, hiddenRaw: raw))
        XCTAssertTrue(ComposeToolbarVisibility.isVisible(.bold, hiddenRaw: raw))
        XCTAssertTrue(ComposeToolbarVisibility.isVisible(.attach, hiddenRaw: raw))
    }

    func testToggleRoundTrip() {
        var raw = ""
        raw = ComposeToolbarVisibility.toggling(.ai, in: raw)
        XCTAssertEqual(ComposeToolbarVisibility.hiddenSet(from: raw), ["ai"])
        raw = ComposeToolbarVisibility.toggling(.math, in: raw)
        XCTAssertEqual(ComposeToolbarVisibility.hiddenSet(from: raw), ["ai", "math"])
        raw = ComposeToolbarVisibility.toggling(.ai, in: raw)
        XCTAssertEqual(ComposeToolbarVisibility.hiddenSet(from: raw), ["math"])
        raw = ComposeToolbarVisibility.toggling(.math, in: raw)
        XCTAssertEqual(raw, "")
    }

    func testEncodeIsSortedStable() {
        let encoded = ComposeToolbarVisibility.encode(["math", "ai", "bold"])
        XCTAssertEqual(encoded, "ai,bold,math")
        XCTAssertEqual(
            ComposeToolbarVisibility.hiddenSet(from: " math , ,bold "),
            ["math", "bold"])
    }

    func testFormatOrderExcludesLinkAndLeftTools() {
        XCTAssertFalse(ComposeToolbarItem.formatOrder.contains(.link))
        XCTAssertFalse(ComposeToolbarItem.formatOrder.contains(.attach))
        XCTAssertEqual(
            ComposeToolbarItem.formatOrder,
            [.bold, .italic, .strikethrough, .code, .heading, .quote, .bullet, .math])
    }

    func testHelpStringsAreNonEmpty() {
        for item in ComposeToolbarItem.allCases {
            XCTAssertFalse(item.help.isEmpty, item.rawValue)
            XCTAssertFalse(item.title.isEmpty, item.rawValue)
            XCTAssertFalse(item.systemImage.isEmpty, item.rawValue)
        }
        XCTAssertTrue(ComposeToolbarItem.math.help.contains("Math"))
        XCTAssertTrue(ComposeToolbarItem.link.help.contains("⌘K"))
    }
}
