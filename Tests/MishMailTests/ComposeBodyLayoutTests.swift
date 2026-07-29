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

    func testSlashWithoutCollapsedQuoteIsIgnored() {
        // Guard order: no-quote wins; slash band only when quote is collapsed.
        let h = ComposeBodyLayout.editorHeights(
            body: "/snip", hasCollapsedQuote: false, slashActive: true)
        XCTAssertEqual(h.min, ComposeBodyLayout.noQuoteMin)
        XCTAssertEqual(h.max, .infinity)
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

    /// First keystroke / last delete must not snap the editor frame.
    /// Empty floor holds until content + slack exceeds it.
    func testEmptyToOneCharDoesNotJump() {
        let empty = ComposeBodyLayout.editorHeights(
            body: "", hasCollapsedQuote: true, slashActive: false)
        let one = ComposeBodyLayout.editorHeights(
            body: "A", hasCollapsedQuote: true, slashActive: false)
        XCTAssertEqual(empty.max, one.max)
        XCTAssertEqual(one.max, ComposeBodyLayout.emptyFloor)
        // Content alone would be shorter — floor is what prevents the snap.
        XCTAssertLessThan(
            ComposeBodyLayout.contentHeight(body: "A")
                + ComposeBodyLayout.contentSlack,
            ComposeBodyLayout.emptyFloor)
    }

    /// Regression: the Revel scheduling reply was ~2–3 lines but reserved
    /// 180pt, leaving the "…" pill mid-void. Short authored bodies stay at
    /// the modest emptyFloor (still well under the old 180).
    func testShortReplyUnderOldFloor() {
        let body = """
        August is open! When is good for you?

        Here's my cal if easier: https://calendar.notion.so/meet/rboger/rb30
        """
        let h = ComposeBodyLayout.editorHeights(
            body: body, hasCollapsedQuote: true, slashActive: false)
        XCTAssertEqual(h.min, h.max)
        XCTAssertLessThan(h.max, 180)
        // Content + slack is under emptyFloor → held at emptyFloor (no hug snap).
        let contentPlusSlack = ComposeBodyLayout.contentHeight(body: body)
            + ComposeBodyLayout.contentSlack
        XCTAssertLessThan(contentPlusSlack, ComposeBodyLayout.emptyFloor)
        XCTAssertEqual(h.max, ComposeBodyLayout.emptyFloor)
    }

    func testHugsOnceContentExceedsFloor() {
        // Enough lines that content + slack clears emptyFloor.
        let lines = (0..<8).map { "line \($0)" }.joined(separator: "\n")
        let contentPlusSlack = ComposeBodyLayout.contentHeight(body: lines)
            + ComposeBodyLayout.contentSlack
        XCTAssertGreaterThan(contentPlusSlack, ComposeBodyLayout.emptyFloor)

        let h = ComposeBodyLayout.editorHeights(
            body: lines, hasCollapsedQuote: true, slashActive: false)
        XCTAssertEqual(h.max, min(contentPlusSlack, ComposeBodyLayout.collapsedCap))
        XCTAssertGreaterThan(h.max, ComposeBodyLayout.emptyFloor)
    }

    func testGrowsWithAuthoredLinesUntilCap() {
        let mid = ComposeBodyLayout.editorHeights(
            body: (0..<8).map { "line \($0)" }.joined(separator: "\n"),
            hasCollapsedQuote: true, slashActive: false)
        let more = ComposeBodyLayout.editorHeights(
            body: (0..<12).map { "line \($0)" }.joined(separator: "\n"),
            hasCollapsedQuote: true, slashActive: false)
        XCTAssertGreaterThan(more.max, mid.max)
        XCTAssertLessThanOrEqual(more.max, ComposeBodyLayout.collapsedCap)
    }

    func testLongBodyCaps() {
        let many = (0..<40).map { "line \($0)" }.joined(separator: "\n")
        let h = ComposeBodyLayout.editorHeights(
            body: many, hasCollapsedQuote: true, slashActive: false)
        XCTAssertEqual(h.min, ComposeBodyLayout.collapsedCap)
        XCTAssertEqual(h.max, ComposeBodyLayout.collapsedCap)
    }
}
