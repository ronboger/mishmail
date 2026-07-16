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

    func testSplitTextWrappedAttribution() {
        // Gmail folds long attribution lines; the split must still fire.
        let body = """
        Sounds good.

        On Thu, Jul 2, 2026 at 6:41 PM Ronald Bogerson
        <ronald.bogerson@example.com> wrote:
        > Sure!
        """
        XCTAssertEqual(QuotedReply.splitText(body)?.head, "Sounds good.")
    }

    func testSplitTextEarliestMarkerWins() {
        // A forward marker above a "wrote:" line must win — splitting at the
        // later attribution would leak the forwarded content above the pill.
        let body = """
        See below.

        ---------- Forwarded message ---------
        From: Alice

        forwarded content

        On Mon, Jun 1, 2026, Bob wrote:
        > older
        """
        XCTAssertEqual(QuotedReply.splitText(body)?.head, "See below.")
    }

    func testSplitTextWroteMidSentenceNotMatched() {
        // "wrote:" must sit on its own attribution line, not inside prose.
        XCTAssertNil(QuotedReply.splitText("On my desk I wrote: a note.\nThat's all."))
    }

    func testSplitTextGreaterThanBlockWithoutAttribution() {
        // Clients often dump nested history as plain `>` lines with no bare
        // "On … wrote:" — only `> On … wrote:` — so the attribution regex
        // never fires. The `>` run itself must still collapse.
        let body = """
        I'm glad to meet you Seyone. thanks for the introduction Ron.

        > family vacation for a few weeks, but i can do early august. i've
        > cc'd my colleague emily hostage, who would also like to meet you.
        > let me know about your availability.
        > best
        > jon.
        > On 2026-07-08, 12:06 AM, "Ron Boger" <ron@ronboger.com>
        > wrote:
        > Hey Seyone and Jon,
        > I think you two will have a good chat
        > Ron
        """
        let split = QuotedReply.splitText(body)
        XCTAssertEqual(
            split?.head,
            "I'm glad to meet you Seyone. thanks for the introduction Ron.")
        XCTAssertTrue(
            split?.tail.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix(">") == true)
    }

    func testSplitTextPeelsGreaterThanBlockAboveAttribution() {
        // Attribution sits below an inlined `>` dump — earliest cut would be
        // "On … wrote:", leaving the dump in the head. Peel it so "…" hides
        // the whole trail.
        let body = """
        Free at 2pm.

        > earlier reply nested in history
        > On Mon, Bob wrote:
        > prior note

        On Thu, Jul 2, 2026 at 6:41 PM, Ron Boger <ron@ronboger.com> wrote:
        > Sure!
        """
        let split = QuotedReply.splitText(body)
        XCTAssertEqual(split?.head, "Free at 2pm.")
        let tail = split?.tail ?? ""
        XCTAssertTrue(tail.contains("> earlier reply nested in history"))
        XCTAssertTrue(tail.contains("On Thu, Jul 2, 2026"))
    }

    func testSplitTextSingleGreaterThanLineNotCollapsed() {
        // One `>` line can be an intentional citation, not a trail.
        let body = """
        See the note below.

        > one cited line only
        """
        XCTAssertNil(QuotedReply.splitText(body))
    }

    func testSplitTextGreaterThanBlockWithSignatureAfterNotCollapsed() {
        // Quote in the middle with prose after is not a trail-to-EOF.
        let body = """
        Intro

        > quoted bit
        > more quoted

        Thanks,
        Jon
        """
        XCTAssertNil(QuotedReply.splitText(body))
    }

    func testSplitTextGreaterThanOnlyBodyStaysVisible() {
        // Whole body is `>` lines — no authored head to keep.
        let body = """
        > only quote
        > more quote
        """
        XCTAssertNil(QuotedReply.splitText(body))
        XCTAssertTrue(QuotedReply.isQuoteOnlyText(body))
    }

    func testSplitTextTrailingShellSnippetsCollapseAsTradeoff() {
        // Documented heuristic tradeoff: ≥2 trailing `>` lines to EOF look
        // like a quote trail, so shell/docs snippets at the end of a message
        // collapse behind "…". One click reveals them. Single-line citations
        // stay put (see testSplitTextSingleGreaterThanLineNotCollapsed).
        let body = """
        To rebuild from a clean tree:

        > make build
        > make test
        """
        let split = QuotedReply.splitText(body)
        XCTAssertEqual(split?.head, "To rebuild from a clean tree:")
        XCTAssertTrue(split?.tail.contains("make build") == true)
        XCTAssertTrue(split?.tail.contains("make test") == true)
    }

    func testSplitTextCRLFGreaterThanBlock() {
        // Gmail plain text often uses CRLF. Swift treats "\r\n" as one
        // Character, so line scans that look for "\n" must normalize first —
        // otherwise a pure `>` trail never splits.
        let body = "I'm free Thursday.\r\n\r\n> family vacation next week\r\n> let me know\r\n"
        let split = QuotedReply.splitText(body)
        XCTAssertEqual(split?.head, "I'm free Thursday.")
        XCTAssertTrue(
            split?.tail.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix(">") == true)
    }

    func testSplitTextCRLFAttributionMarker() {
        let body = "Sounds good.\r\n\r\nOn Thu, Jul 2, 2026 at 6:41 PM, Ron wrote:\r\n> Sure!\r\n"
        let split = QuotedReply.splitText(body)
        XCTAssertEqual(split?.head, "Sounds good.")
        XCTAssertTrue(
            split?.tail.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix("On Thu") == true)
    }

    func testIsQuoteOnlyTextCRLFGreaterThanOnly() {
        let body = "> only quote\r\n> more quote\r\n"
        XCTAssertTrue(QuotedReply.isQuoteOnlyText(body))
        XCTAssertNil(QuotedReply.splitText(body))
    }

    func testSplitTextMarkerBeatsLaterGreaterThanBlock() {
        // Both boundaries match: bare "On … wrote:" and a pure `>` run under
        // it. Earliest wins (min of the two cuts) so the attribution stays in
        // the trail — cutting at the first `>` would drop "On … wrote:".
        let body = """
        Sounds good.

        On Thu, Jul 2, 2026 at 6:41 PM, Ron Boger <ron@ronboger.com> wrote:
        > Sure! Anyone in the 10-20M size?
        > Happy to intro offline too.
        """
        let split = QuotedReply.splitText(body)
        XCTAssertEqual(split?.head, "Sounds good.")
        let tail = split?.tail ?? ""
        XCTAssertTrue(tail.contains("On Thu, Jul 2, 2026"))
        XCTAssertTrue(tail.contains("> Sure!"))
        XCTAssertTrue(tail.contains("> Happy to intro"))
    }

    func testSplitTextGreaterThanDumpAboveMarkerPeelsFullTrail() {
        // Shape Fable called out: `>` dump starts before a bare marker later.
        // Pure-to-EOF greaterThan can't fire (marker is non-quoted after the
        // dump), so the cut is the marker and peel moves the dump into the
        // trail — head must not retain any `>` lines.
        let body = """
        Free at 2pm on the 10th.

        > family vacation for a few weeks
        > On 2026-07-08, Ron wrote:
        > Hey Seyone and Jon

        On Thu, Jul 10, 2026 at 3:00 PM, Erica Maldonado <e@voleon.com> wrote:
        > earlier thread bit
        """
        let split = QuotedReply.splitText(body)
        XCTAssertEqual(split?.head, "Free at 2pm on the 10th.")
        XCTAssertFalse(split?.head.contains(">") == true)
        let tail = split?.tail ?? ""
        XCTAssertTrue(tail.contains("> family vacation"))
        XCTAssertTrue(tail.contains("On Thu, Jul 10, 2026"))
    }

    // MARK: - HTML

    func testHasHTMLQuoteGmail() {
        let html = #"<div dir="ltr">Sounds good.</div><div class="gmail_quote"><blockquote>old</blockquote></div>"#
        XCTAssertTrue(QuotedReply.hasHTMLQuote(html))
    }

    func testAuthoredHTMLHeadReturnsRawMarkupWithoutCopyingTail() {
        let html = #"<div dir="ltr">Sounds good.</div><div class="gmail_quote"><blockquote>old</blockquote></div>"#
        let head = QuotedReply.authoredHTMLHead(html)
        XCTAssertEqual(head, #"<div dir="ltr">Sounds good.</div>"#)
        XCTAssertEqual(QuotedReply.authoredHTML(html), head)
    }

    func testSplitHTMLRejectsQuoteOnlyBody() {
        let html = #"<div>&nbsp;</div><blockquote type="cite">old</blockquote>"#
        XCTAssertNil(QuotedReply.authoredHTMLHead(html))
        XCTAssertEqual(QuotedReply.authoredHTML(html), html)
    }

    func testAuthoredHTMLReturnsOriginalWithoutMarker() {
        let html = "<div>standalone message</div>"
        XCTAssertEqual(QuotedReply.authoredHTML(html), html)
    }

    func testAuthoredHTMLHeadCanBoundOversizedScan() {
        let html = String(repeating: "a", count: 100)
            + #"<div class="gmail_quote">old</div>"#
        XCTAssertNil(QuotedReply.authoredHTMLHead(html, scanCharacterLimit: 50))
        XCTAssertEqual(
            QuotedReply.authoredHTMLHead(html, scanCharacterLimit: 150),
            String(repeating: "a", count: 100))
    }

    func testAuthoredHTMLHeadFindsMarkerStraddlingScanBoundary() {
        let head = String(repeating: "a", count: 95)
        let html = head + #"<div class="gmail_quote">old</div>"#
        XCTAssertEqual(
            QuotedReply.authoredHTMLHead(html, scanCharacterLimit: 100),
            head)
    }

    func testAuthoredHTMLHeadRejectsMarkerStartingAfterScanBoundary() {
        let html = String(repeating: "a", count: 101)
            + #"<div class="gmail_quote">old</div>"#
        XCTAssertNil(QuotedReply.authoredHTMLHead(html, scanCharacterLimit: 100))
    }

    func testHasHTMLQuoteAppleMailCite() {
        let html = #"<div>New text</div><blockquote type="cite"><div>old</div></blockquote>"#
        XCTAssertTrue(QuotedReply.hasHTMLQuote(html))
    }

    func testHasHTMLQuoteOutlook() {
        let html = #"<p>reply text</p><div id="divRplyFwdMsg"><b>From:</b> x</div>"#
        XCTAssertTrue(QuotedReply.hasHTMLQuote(html))
    }

    func testHasHTMLQuoteBlockquoteGmailClass() {
        // Some clients emit the gmail_quote class on a blockquote, not a div;
        // detection and the hide CSS must both cover it.
        let html = #"<div>new text</div><blockquote class="gmail_quote">old</blockquote>"#
        XCTAssertTrue(QuotedReply.hasHTMLQuote(html))
    }

    func testHasHTMLQuoteSingleQuotedAttrs() {
        let html = "<div>new</div><div class='gmail_quote'>old</div>"
        XCTAssertTrue(QuotedReply.hasHTMLQuote(html))
    }

    func testHasHTMLQuoteEntityOnlyWrapperStaysVisible() {
        // &#160; is a non-breaking space — the head is still effectively
        // empty, so nothing would remain visible if the quote collapsed.
        let html = #"<div>&#160; &nbsp;</div><div class="gmail_quote">old</div>"#
        XCTAssertFalse(QuotedReply.hasHTMLQuote(html))
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

    // MARK: - Authored preview (draft cards)

    func testAuthoredPreviewPlainTextStripsQuote() {
        let body = """
        Hey — happy to chat 1:1.

        On Thu, Jul 12, 2026 at 11:00 AM, Matt <m@x.com> wrote:
        > Let's find time
        """
        XCTAssertEqual(
            QuotedReply.authoredPreview(text: body, html: nil),
            "Hey — happy to chat 1:1.")
    }

    func testAuthoredPreviewHTMLFallsBackWhenTextEmpty() {
        let html = #"<div dir="ltr">Hey MHappy to chat 1:1</div><br>"#
            + #"<div class="gmail_quote"><blockquote>old thread</blockquote></div>"#
        XCTAssertEqual(
            QuotedReply.authoredPreview(text: "", html: html),
            "Hey MHappy to chat 1:1")
    }

    func testAuthoredPreviewPrefersPlainTextOverHTML() {
        // Compose keeps plain + HTML; plain split is the source of truth for
        // what the user typed above the collapsed quote.
        let text = "Short note.\n\nOn Mon, Bob wrote:\n> prior"
        let html = #"<div>Short note.</div><div class="gmail_quote">prior</div>"#
        XCTAssertEqual(
            QuotedReply.authoredPreview(text: text, html: html),
            "Short note.")
    }

    func testAuthoredPreviewNoQuoteReturnsFullBody() {
        XCTAssertEqual(
            QuotedReply.authoredPreview(text: "Just a draft.", html: nil),
            "Just a draft.")
    }

    func testAuthoredPreviewEmpty() {
        XCTAssertEqual(QuotedReply.authoredPreview(text: "", html: nil), "")
        XCTAssertEqual(QuotedReply.authoredPreview(text: "  \n", html: nil), "")
    }

    func testAuthoredPreviewQuoteOnlyIsEmpty() {
        // Reply → quote auto-inserted → save without typing. splitText is nil
        // (empty head) but the body *is* a quote — must not dump the trail.
        let body = """

        On Thu, Jul 12, 2026 at 11:00 AM, Matt <m@x.com> wrote:
        > Let's find time
        """
        XCTAssertTrue(QuotedReply.isQuoteOnlyText(body))
        XCTAssertEqual(QuotedReply.authoredPreview(text: body, html: nil), "")
    }

    func testAuthoredPreviewQuoteOnlyAtStart() {
        let body = "On Mon, Jun 1, 2026, Bob wrote:\n> prior"
        // Marker needs a leading newline in the regex — bodies that *start*
        // with "On … wrote:" without a preceding newline are not quote-only
        // under the same rule as splitText (would otherwise hide real prose
        // that happens to open with those words).
        XCTAssertFalse(QuotedReply.isQuoteOnlyText(body))
    }

    func testAuthoredPreviewQuoteOnlyHTMLEmpty() {
        let html = #"<br><div class="gmail_quote"><blockquote>old</blockquote></div>"#
        XCTAssertEqual(QuotedReply.authoredPreview(text: "", html: html), "")
    }

    func testAuthoredPreviewQuoteOnlyPlainDefersToHTMLHead() {
        // Plain is quote-only; HTML still has authored head — prefer that.
        let plain = "\n\nOn Thu, Jul 12, 2026 at 11:00 AM, Matt <m@x.com> wrote:\n> old"
        let html = #"<div dir="ltr">Still drafting</div><div class="gmail_quote">old</div>"#
        XCTAssertEqual(
            QuotedReply.authoredPreview(text: plain, html: html),
            "Still drafting")
    }
}
