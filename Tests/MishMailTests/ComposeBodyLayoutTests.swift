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

    func testNoCollapsedQuoteHugsContent() {
        // Short body stays at noQuoteMin floor (not unbounded flex).
        let short = ComposeBodyLayout.editorHeights(
            body: "Hi", hasCollapsedQuote: false, slashActive: false)
        XCTAssertEqual(short.min, ComposeBodyLayout.noQuoteMin)
        XCTAssertEqual(short.max, ComposeBodyLayout.noQuoteMin)

        // Long body caps at content + slack so the collapse pill hugs text.
        let lines = (0..<12).map { "line \($0)" }.joined(separator: "\n")
        let long = ComposeBodyLayout.editorHeights(
            body: lines, hasCollapsedQuote: false, slashActive: false)
        let expected = max(
            ComposeBodyLayout.noQuoteMin,
            ComposeBodyLayout.contentHeight(body: lines)
                + ComposeBodyLayout.contentSlack)
        XCTAssertEqual(long.min, ComposeBodyLayout.noQuoteMin)
        XCTAssertEqual(long.max, expected)
        XCTAssertGreaterThan(long.max, ComposeBodyLayout.noQuoteMin)
        XCTAssertNotEqual(long.max, .infinity)
    }

    func testNoCollapsedQuoteEmptyBodyUsesFloor() {
        let h = ComposeBodyLayout.editorHeights(
            body: "", hasCollapsedQuote: false, slashActive: false)
        XCTAssertEqual(h.min, ComposeBodyLayout.noQuoteMin)
        XCTAssertEqual(h.max, ComposeBodyLayout.noQuoteMin)
    }

    func testSlashActiveUsesLowBand() {
        let h = ComposeBodyLayout.editorHeights(
            body: "Hi\nthere", hasCollapsedQuote: true, slashActive: true)
        XCTAssertEqual(h.min, ComposeBodyLayout.slashFloor)
        XCTAssertEqual(h.max, ComposeBodyLayout.slashCap)
        // Picker band must stay under the old 180pt floor so the list fits.
        XCTAssertLessThan(h.max, 180)
    }

    func testSlashWithoutCollapsedQuoteStillHugs() {
        // Guard order: no-quote wins; slash band only when quote is collapsed.
        // Max still hugs content (not infinity) so an inlined quote's pill
        // placement is correct even while the slash picker is open.
        let h = ComposeBodyLayout.editorHeights(
            body: "/snip", hasCollapsedQuote: false, slashActive: true)
        XCTAssertEqual(h.min, ComposeBodyLayout.noQuoteMin)
        let expected = max(
            ComposeBodyLayout.noQuoteMin,
            ComposeBodyLayout.contentHeight(body: "/snip")
                + ComposeBodyLayout.contentSlack)
        XCTAssertEqual(h.max, expected)
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

    func testWhitespaceOnlySingleLineStaysAtFloor() {
        // Spaces/tabs only → one visual line under the floor.
        let h = ComposeBodyLayout.editorHeights(
            body: "  \t  ", hasCollapsedQuote: true, slashActive: false)
        XCTAssertEqual(h.min, ComposeBodyLayout.emptyFloor)
        XCTAssertEqual(h.max, ComposeBodyLayout.emptyFloor)
    }

    /// Newline-only drafts still count visual lines so the frame grows
    /// instead of scrolling inside a fixed emptyFloor.
    func testNewlineOnlyBodyGrowsWithLines() {
        let body = String(repeating: "\n", count: 8)
        let h = ComposeBodyLayout.editorHeights(
            body: body, hasCollapsedQuote: true, slashActive: false)
        let expected = min(
            max(ComposeBodyLayout.contentHeight(body: body)
                + ComposeBodyLayout.contentSlack,
                ComposeBodyLayout.emptyFloor),
            ComposeBodyLayout.collapsedCap)
        XCTAssertEqual(h.min, ComposeBodyLayout.emptyFloor)
        XCTAssertEqual(h.max, expected)
        XCTAssertGreaterThan(h.max, ComposeBodyLayout.emptyFloor)
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
        XCTAssertLessThan(contentPlusSlack, ComposeBodyLayout.collapsedCap)

        let h = ComposeBodyLayout.editorHeights(
            body: lines, hasCollapsedQuote: true, slashActive: false)
        // Max hugs content; min stays compressible at emptyFloor so a fixed
        // card can shrink the editor and keep pill + footer on-screen.
        XCTAssertEqual(h.min, ComposeBodyLayout.emptyFloor)
        XCTAssertEqual(h.max, contentPlusSlack)
        XCTAssertGreaterThan(h.max, ComposeBodyLayout.emptyFloor)
        XCTAssertLessThan(h.min, h.max)
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
        XCTAssertEqual(mid.min, ComposeBodyLayout.emptyFloor)
        XCTAssertEqual(more.min, ComposeBodyLayout.emptyFloor)
    }

    /// Long body + collapsed quote: max hits collapsedCap; min stays at
    /// emptyFloor so the editor can compress inside a fixed compose card.
    func testLongBodyCapsWithCompressibleMin() {
        let many = (0..<40).map { "line \($0)" }.joined(separator: "\n")
        let h = ComposeBodyLayout.editorHeights(
            body: many, hasCollapsedQuote: true, slashActive: false)
        XCTAssertEqual(h.min, ComposeBodyLayout.emptyFloor)
        XCTAssertEqual(h.max, ComposeBodyLayout.collapsedCap)
        XCTAssertLessThan(h.min, h.max)
    }

    /// A full-height split composer should spend its available whitespace on
    /// the authored reply before falling back to the editor's internal scroll.
    func testSplitBodyUsesFullContentHeightBeyondCompactCap() {
        let many = (0..<24).map { "line \($0)" }.joined(separator: "\n")
        let contentHeight = ComposeBodyLayout.contentHeight(body: many)
            + ComposeBodyLayout.contentSlack
        XCTAssertGreaterThan(contentHeight, ComposeBodyLayout.collapsedCap)

        let h = ComposeBodyLayout.editorHeights(
            body: many,
            hasCollapsedQuote: true,
            slashActive: false,
            collapsedQuoteCap: .infinity)

        XCTAssertEqual(h.min, ComposeBodyLayout.emptyFloor)
        XCTAssertEqual(h.max, contentHeight)
    }

    /// Medium body (raw between emptyFloor and collapsedCap): max == raw,
    /// min stays at emptyFloor for compression headroom.
    func testMediumBodyCompressibleMinHugsMax() {
        let lines = (0..<10).map { "line \($0)" }.joined(separator: "\n")
        let raw = ComposeBodyLayout.contentHeight(body: lines)
            + ComposeBodyLayout.contentSlack
        XCTAssertGreaterThan(raw, ComposeBodyLayout.emptyFloor)
        XCTAssertLessThan(raw, ComposeBodyLayout.collapsedCap)

        let h = ComposeBodyLayout.editorHeights(
            body: lines, hasCollapsedQuote: true, slashActive: false)
        XCTAssertEqual(h.min, ComposeBodyLayout.emptyFloor)
        XCTAssertEqual(h.max, raw)
    }
}

