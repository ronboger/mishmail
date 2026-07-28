import XCTest

final class SlashSnippetPickerLayoutTests: XCTestCase {

    func testEmptyListHasZeroHeight() {
        XCTAssertEqual(SlashSnippetPickerLayout.listHeight(snippetCount: 0), 0)
        XCTAssertEqual(SlashSnippetPickerLayout.listHeight(snippetCount: -1), 0)
    }

    func testSingleRowIsAtLeastOneRowTall() {
        let h = SlashSnippetPickerLayout.listHeight(snippetCount: 1)
        // Header/footer of the picker are outside this; the list itself must
        // claim a real row so it can't collapse to 0 under a tight VStack.
        XCTAssertGreaterThan(h, 0)
        XCTAssertEqual(h, SlashSnippetPickerLayout.rowHeight
                       + SlashSnippetPickerLayout.listPadding)
    }

    func testGrowsWithCountUntilCap() {
        let two = SlashSnippetPickerLayout.listHeight(snippetCount: 2)
        let three = SlashSnippetPickerLayout.listHeight(snippetCount: 3)
        XCTAssertGreaterThan(three, two)
        XCTAssertLessThanOrEqual(two, SlashSnippetPickerLayout.maxListHeight)
        XCTAssertLessThanOrEqual(three, SlashSnippetPickerLayout.maxListHeight)
    }

    func testLongListCapsAtMax() {
        let many = SlashSnippetPickerLayout.listHeight(snippetCount: 50)
        XCTAssertEqual(many, SlashSnippetPickerLayout.maxListHeight)
        // Cap must fit the starter set + a few user snippets without scroll
        // on the common case, but stay short enough for the inline reply card.
        XCTAssertGreaterThanOrEqual(SlashSnippetPickerLayout.maxListHeight, 100)
        XCTAssertLessThanOrEqual(SlashSnippetPickerLayout.maxListHeight, 180)
    }

    /// Regression guard for the reply-card bug: under a short parent the
    /// old maxHeight-only ScrollView compressed to 0 while chrome still
    /// painted. A positive fixed height for any non-empty match list is
    /// what keeps rows visible when the quote Spacer fights for space.
    func testNonEmptyMatchListNeverCollapses() {
        for n in 1...10 {
            XCTAssertGreaterThan(
                SlashSnippetPickerLayout.listHeight(snippetCount: n), 0,
                "count \(n) must keep a non-zero list height")
        }
    }
}
