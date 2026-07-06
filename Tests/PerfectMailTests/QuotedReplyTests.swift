import XCTest

final class QuotedReplyTests: XCTestCase {

    // MARK: - Plain text

    func testSplitTextOnWroteAttribution() {
        let body = """
        Sounds good. I connected you to Amit at Earl Grey ($10M fund size)

        Rohan Gandhi

        On Thu, Jul 2, 2026 at 6:41 PM, Ron Boger <ron@ronboger.com> wrote:
        > Sure! Anyone in the 10-20M size?
        """
        let split = QuotedReply.splitText(body)
        XCTAssertEqual(split?.head,
                       "Sounds good. I connected you to Amit at Earl Grey ($10M fund size)\n\nRohan Gandhi")
        XCTAssertEqual(split?.tail.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("On Thu"), true)
    }

    func testSplitTextForwardMarker() {
        let body = "FYI, see below.\n\n---------- Forwarded message ---------\nFrom: X"
        let split = QuotedReply.splitText(body)
        XCTAssertEqual(split?.head, "FYI, see below.")
    }

    func testSplitTextNoQuote() {
        XCTAssertNil(QuotedReply.splitText("Just a plain message.\nNothing quoted."))
    }

    func testSplitTextQuoteOnlyStaysVisible() {
        // No authored text above the trail — collapsing would blank the card.
        let body = "\n\nOn Thu, Jul 2, 2026, Ron wrote:\n> hello"
        XCTAssertNil(QuotedReply.splitText(body))
    }

    func testSplitTextWroteMidSentenceNotMatched() {
        // "wrote:" must sit on its own attribution line, not inside prose.
        XCTAssertNil(QuotedReply.splitText("On my desk I wrote: a note.\nThat's all."))
    }

    // MARK: - HTML

    func testHasHTMLQuoteGmail() {
        let html = #"<div dir="ltr">Sounds good.</div><div class="gmail_quote"><blockquote>old</blockquote></div>"#
        XCTAssertTrue(QuotedReply.hasHTMLQuote(html))
    }

    func testHasHTMLQuoteAppleMailCite() {
        let html = #"<div>New text</div><blockquote type="cite"><div>old</div></blockquote>"#
        XCTAssertTrue(QuotedReply.hasHTMLQuote(html))
    }

    func testHasHTMLQuoteOutlook() {
        let html = #"<p>reply text</p><div id="divRplyFwdMsg"><b>From:</b> x</div>"#
        XCTAssertTrue(QuotedReply.hasHTMLQuote(html))
    }

    func testHasHTMLQuoteNoQuote() {
        XCTAssertFalse(QuotedReply.hasHTMLQuote("<div>Just a newsletter with a <blockquote>pull quote</blockquote></div>"))
    }

    func testHasHTMLQuoteQuoteOnlyStaysVisible() {
        // Nothing above the quoted container — hiding it would blank the card.
        let html = #"<div class="gmail_quote"><div>the whole message</div></div>"#
        XCTAssertFalse(QuotedReply.hasHTMLQuote(html))
    }

    func testHasHTMLQuoteIgnoresEmptyWrapperAboveQuote() {
        let html = #"<div dir="ltr"><br></div><div class="gmail_quote">old</div>"#
        XCTAssertFalse(QuotedReply.hasHTMLQuote(html))
    }
}
