import XCTest

final class ComposeBodyLayoutTests: XCTestCase {

    // MARK: - contentHeight

    func testContentHeightCountsVisualLines() {
        // Single short line → padding + 1× lineHeight.
        let one = ComposeBodyLayout.contentHeight(body: "Hi")
        XCTAssertEqual(one,
                       ComposeBodyLayout.editorPadding
                       + ComposeBodyLayout.lineHeight)

        // Blank line still counts as one visual line (max(count, 1)).
        let blank = ComposeBodyLayout.contentHeight(body: "a\n\nb")
        XCTAssertEqual(blank,
                       ComposeBodyLayout.editorPadding
                       + 3 * ComposeBodyLayout.lineHeight)
    }

    func testContentHeightWrapsLongLines() {
        let long = String(repeating: "x", count: ComposeBodyLayout.charsPerLine * 2)
        let h = ComposeBodyLayout.contentHeight(body: long)
        XCTAssertEqual(h,
                       ComposeBodyLayout.editorPadding
                       + 2 * ComposeBodyLayout.lineHeight)
    }

    // MARK: - no quote / slash

    func testNoCollapsedQuoteFlexes() {
        let h = ComposeBodyLayout.editorHeights(
            body: "anything", hasCollapsedQuote: false, slashActive: false)
        XCTAssertEqual(h.min, ComposeBodyLayout.noQuoteMin)
        XCTAssertEqual(h.max, .infinity)
    }

    func testSlashActiveUsesLowBand() {
        let h = ComposeBodyLayout.editorHeights(
            body: "Hi\nthere", hasCollapsedQuote: true, slashActive: true)
        XCTAssertEqual(h.min, ComposeBodyLayout.slashFloor)
        XCTAssertEqual(h.max, ComposeBodyLayout.slashCap)
        // Picker band must stay under the old 180pt floor so the list fits.
        XCTAssertLessThan(h.max, 180)
    }

    // MARK: - empty vs short reply (the screenshot bug)

    func testEmptyCollapsedQuoteUsesModestFloor() {
        let h = ComposeBodyLayout.editorHeights(
            body: "", hasCollapsedQuote: true, slashActive: false)
        XCTAssertEqual(h.min, ComposeBodyLayout.emptyFloor)
        XCTAssertEqual(h.max, ComposeBodyLayout.emptyFloor)
        // Still a real writing surface, but not the old 180pt void.
        XCTAssertGreaterThanOrEqual(h.min, 80)
        XCTAssertLessThan(h.min, 180)
    }

    func testWhitespaceOnlyBodyTreatedAsEmpty() {
        let h = ComposeBodyLayout.editorHeights(
            body: "  \n\t\n  ", hasCollapsedQuote: true, slashActive: false)
        XCTAssertEqual(h.min, ComposeBodyLayout.emptyFloor)
        XCTAssertEqual(h.max, ComposeBodyLayout.emptyFloor)
    }

    /// Regression: the Revel scheduling reply was ~2–3 lines but reserved
    /// 180pt, leaving the "…" pill mid-void. Short authored bodies must hug
    /// content well under that old floor.
    func testShortReplyHugsContentUnderOldFloor() {
        let body = """
        August is open! When is good for you?

        Here's my cal if easier: https://calendar.notion.so/meet/rboger/rb30
        """
        let h = ComposeBodyLayout.editorHeights(
            body: body, hasCollapsedQuote: true, slashActive: false)
        XCTAssertEqual(h.min, h.max)
        XCTAssertLessThan(h.max, 180)
        // At least content + slack; not collapsed to a one-liner strip.
        let expected = min(
            max(ComposeBodyLayout.contentHeight(body: body)
                + ComposeBodyLayout.contentSlack,
                ComposeBodyLayout.nonEmptyFloor),
            ComposeBodyLayout.collapsedCap)
        XCTAssertEqual(h.max, expected)
        XCTAssertGreaterThan(h.max, ComposeBodyLayout.nonEmptyFloor)
    }

    func testGrowsWithAuthoredLinesUntilCap() {
        let short = ComposeBodyLayout.editorHeights(
            body: "one line", hasCollapsedQuote: true, slashActive: false)
        let mid = ComposeBodyLayout.editorHeights(
            body: (0..<8).map { "line \($0)" }.joined(separator: "\n"),
            hasCollapsedQuote: true, slashActive: false)
        XCTAssertGreaterThan(mid.max, short.max)
        XCTAssertLessThanOrEqual(mid.max, ComposeBodyLayout.collapsedCap)
    }

    func testLongBodyCaps() {
        let many = (0..<40).map { "line \($0)" }.joined(separator: "\n")
        let h = ComposeBodyLayout.editorHeights(
            body: many, hasCollapsedQuote: true, slashActive: false)
        XCTAssertEqual(h.min, ComposeBodyLayout.collapsedCap)
        XCTAssertEqual(h.max, ComposeBodyLayout.collapsedCap)
    }
}
