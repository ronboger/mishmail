import XCTest

final class MailLayoutTests: XCTestCase {
    func testWideWindowUsesThreePanes() {
        XCTAssertEqual(MailLayout.mode(width: 1_200, readingPaneHidden: false,
                                       hasSelection: true), .threePane)
    }

    func testCompactWindowShowsSelectedConversationInsteadOfSqueezingIt() {
        XCTAssertEqual(MailLayout.mode(width: 900, readingPaneHidden: false,
                                       hasSelection: true), .compactDetail)
    }

    func testCompactWindowShowsListWithoutSelection() {
        XCTAssertEqual(MailLayout.mode(width: 900, readingPaneHidden: false,
                                       hasSelection: false), .list)
    }

    func testHiddenReadingPaneAlwaysShowsList() {
        XCTAssertEqual(MailLayout.mode(width: 1_400, readingPaneHidden: true,
                                       hasSelection: true), .list)
    }

    func testThreadFocusFillsTheWindowWhenAConversationIsSelected() {
        XCTAssertEqual(MailLayout.mode(width: 1_200, readingPaneHidden: false,
                                       hasSelection: true, threadFocus: true),
                       .threadFocus)
    }

    func testThreadFocusWithoutSelectionFallsBack() {
        XCTAssertEqual(MailLayout.mode(width: 1_200, readingPaneHidden: false,
                                       hasSelection: false, threadFocus: true),
                       .threePane)
        XCTAssertEqual(MailLayout.mode(width: 1_200, readingPaneHidden: true,
                                       hasSelection: false, threadFocus: true),
                       .list)
    }
}
