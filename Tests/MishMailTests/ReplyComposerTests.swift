import XCTest

final class ReplyComposerTests: XCTestCase {

    private let date = Date(timeIntervalSince1970: 1_783_372_500) // ~Jul 6, 2026

    private func message(
        from: String = "Yaniv Erlich <yaniv@undecimalbio.com>",
        bodyText: String = "Thanks a lot for the vote of confidence.",
        bodyHTML: String? = #"<div dir="ltr">Thanks a lot for the vote of confidence.</div>"#,
        labels: String = "INBOX"
    ) -> Message {
        Message(
            id: "ron@x.com:m1", accountId: "ron@x.com", gmailId: "m1",
            threadId: "ron@x.com:t1", fromHeader: from, toHeader: "ron@x.com",
            ccHeader: "", bccHeader: "", subject: "Re: deal",
            date: date, snippet: "Thanks", bodyText: bodyText, bodyHTML: bodyHTML,
            messageIdHeader: "<m1@mail>", referencesHeader: "",
            labelIds: labels, isUnread: false, hasAttachment: false)
    }

    // MARK: - Plain quote

    func testPlainQuoteHasAttributionAndPrefixedLines() {
        let q = ReplyComposer.plainQuote(of: message())
        XCTAssertTrue(q.hasPrefix("\nOn "), "leading newline for fullBody join")
        XCTAssertTrue(q.contains("Yaniv Erlich <yaniv@undecimalbio.com> wrote:"))
        XCTAssertTrue(q.contains("> Thanks a lot for the vote of confidence."))
    }

    func testPlainQuotePrefixesNestedHistory() {
        let body = "Sounds great!\n\nOn earlier, Ron wrote:\n> Hi"
        let q = ReplyComposer.plainQuote(of: message(bodyText: body, bodyHTML: nil))
        // Every line of the original is one `>` deeper — including prior attributions.
        XCTAssertTrue(q.contains("> Sounds great!"))
        XCTAssertTrue(q.contains("> On earlier, Ron wrote:"))
        XCTAssertTrue(q.contains("> > Hi"))
    }

    func testPlainQuoteIsDeterministic() {
        let m = message()
        XCTAssertEqual(ReplyComposer.plainQuote(of: m), ReplyComposer.plainQuote(of: m))
    }

    // MARK: - Match / userText

    func testUserTextWhenQuoteUntouched() {
        let m = message()
        let quote = ReplyComposer.plainQuote(of: m)
        // Compose joins as head + "\n\n" + quotedTail (quotedTail == plainQuote).
        let body = "Hi Yaniv - let's close the deal? - Ron\n\n" + quote
        XCTAssertEqual(ReplyComposer.userText(inBody: body, expectedQuote: quote),
                       "Hi Yaniv - let's close the deal? - Ron")
    }

    func testUserTextEmptyWhenNothingTyped() {
        let m = message()
        let quote = ReplyComposer.plainQuote(of: m)
        XCTAssertEqual(ReplyComposer.userText(inBody: "\n\n" + quote, expectedQuote: quote), "")
    }

    func testUserTextNilWhenQuoteEdited() {
        let m = message()
        let quote = ReplyComposer.plainQuote(of: m)
        let edited = ("note\n\n" + quote).replacingOccurrences(of: "vote", with: "note")
        XCTAssertNil(ReplyComposer.userText(inBody: edited, expectedQuote: quote))
    }

    func testMatchHTMLUpgradeHappyPath() {
        let m = message()
        let body = "Following up.\n\n" + ReplyComposer.plainQuote(of: m)
        let match = ReplyComposer.matchHTMLUpgrade(body: body, original: m)
        XCTAssertEqual(match?.userText, "Following up.")
        XCTAssertEqual(match?.original.id, m.id)
    }

    func testMatchHTMLUpgradeFailsWhenQuoteRemoved() {
        let m = message()
        XCTAssertNil(ReplyComposer.matchHTMLUpgrade(body: "just my text", original: m))
    }

    // MARK: - HTML body (Gmail-shaped)

    func testHTMLBodyWrapsOriginalInGmailQuote() {
        let m = message()
        let html = ReplyComposer.htmlBody(
            userText: "Hi Yaniv - let's close the deal? - Ron", original: m)

        XCTAssertTrue(html.contains("Hi Yaniv - let's close the deal? - Ron"))
        XCTAssertTrue(html.contains("class=\"gmail_quote\""))
        XCTAssertTrue(html.contains("class=\"gmail_attr\""))
        XCTAssertTrue(html.contains("wrote:<br>"))
        // Original HTML survives nested — not re-quoted as plain `>` lines.
        XCTAssertTrue(html.contains(#"<div dir="ltr">Thanks a lot for the vote of confidence.</div>"#))
        XCTAssertTrue(html.contains("<blockquote class=\"gmail_quote\""))
        // Must not flatten the trail into a single markdown cite block only.
        XCTAssertFalse(html.contains("> Thanks a lot"))
    }

    func testHTMLBodyEscapesUserTextWhenPlain() {
        let m = message()
        let html = ReplyComposer.htmlBody(userText: "See <b>this</b> & that", original: m)
        XCTAssertTrue(html.contains("See &lt;b&gt;this&lt;/b&gt; &amp; that"))
        XCTAssertFalse(html.contains("<b>this</b>"))
    }

    func testHTMLBodyRendersUserMarkdown() {
        let m = message()
        let html = ReplyComposer.htmlBody(userText: "Hello **world**", original: m)
        XCTAssertTrue(html.contains("<strong>world</strong>"), html)
        XCTAssertTrue(html.contains("class=\"gmail_quote\""))
    }

    func testHTMLBodyFallsBackToPlainWhenNoOriginalHTML() {
        let m = message(bodyText: "Plain only\nSecond line", bodyHTML: nil)
        let html = ReplyComposer.htmlBody(userText: "ack", original: m)
        XCTAssertTrue(html.contains("Plain only<br>Second line"))
        XCTAssertTrue(html.contains("class=\"gmail_quote\""))
    }

    func testHTMLBodyWorksWithEmptyUserText() {
        // Send with only a quote (rare) still produces a valid gmail trail.
        let m = message()
        let html = ReplyComposer.htmlBody(userText: "", original: m)
        XCTAssertTrue(html.hasPrefix("<br><div class=\"gmail_quote\">"), html)
        XCTAssertTrue(html.contains("Thanks a lot"))
    }

    func testHTMLBodyStripsCidImagesAndStyle() {
        let dirty = """
        <html><head><style>div{color:red}</style></head><body>
        <div>Hi</div>
        <img src="cid:logo@x" alt="logo">
        <img src="https://ok.example/a.png">
        </body></html>
        """
        let m = message(bodyHTML: dirty)
        let html = ReplyComposer.htmlBody(userText: "ack", original: m)
        XCTAssertFalse(html.contains("<style"), html)
        XCTAssertFalse(html.contains("cid:logo"), html)
        XCTAssertFalse(html.contains("<html"), html)
        XCTAssertTrue(html.contains("https://ok.example/a.png"), html)
        XCTAssertTrue(html.contains("<div>Hi</div>"), html)
    }

    func testFormatDateIsStableAcrossCalls() {
        let d = Date(timeIntervalSince1970: 1_783_372_500)
        XCTAssertEqual(ReplyComposer.formatDate(d), ReplyComposer.formatDate(d))
        // Pinned en_US_POSIX shape — not locale-sensitive abbreviated style.
        XCTAssertTrue(ReplyComposer.formatDate(d).contains("at"))
    }
}
