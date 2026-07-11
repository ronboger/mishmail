import XCTest

final class ThreadExporterTests: XCTestCase {

    private func message(
        id: String = "a:1",
        from: String = "Alice <alice@x.com>",
        to: String = "me@y.com",
        cc: String = "",
        subject: String = "Hello",
        date: Date = Date(timeIntervalSince1970: 1_720_000_000),
        bodyText: String = "Hi there",
        bodyHTML: String? = nil
    ) -> Message {
        Message(
            id: id, accountId: "a", gmailId: "g1", threadId: "a:t1",
            fromHeader: from, toHeader: to, ccHeader: cc, bccHeader: "",
            subject: subject, date: date, snippet: "",
            bodyText: bodyText, bodyHTML: bodyHTML,
            messageIdHeader: "", referencesHeader: "", labelIds: "",
            isUnread: false, hasAttachment: false)
    }

    func testMarkdownIncludesSubjectAndBodies() {
        let msgs = [
            message(id: "a:1", bodyText: "First"),
            message(id: "a:2", from: "Bob <bob@x.com>", bodyText: "Second"),
        ]
        let md = ThreadExporter.markdown(subject: "Thread subject", messages: msgs)
        XCTAssertTrue(md.hasPrefix("# Thread subject\n"), md)
        XCTAssertTrue(md.contains("2 messages"), md)
        XCTAssertTrue(md.contains("## Alice"), md)
        XCTAssertTrue(md.contains("**From:** Alice <alice@x.com>"), md)
        XCTAssertTrue(md.contains("First"), md)
        XCTAssertTrue(md.contains("---"), md)
        XCTAssertTrue(md.contains("Second"), md)
        XCTAssertTrue(md.hasSuffix("\n"), md)
    }

    func testEmptySubjectPlaceholder() {
        let md = ThreadExporter.markdown(subject: "  ", messages: [message()])
        XCTAssertTrue(md.hasPrefix("# (no subject)\n"), md)
    }

    func testHTMLFallbackWhenTextEmpty() {
        let msg = message(bodyText: "", bodyHTML: "<p>Hello <b>world</b></p>")
        let md = ThreadExporter.markdown(subject: "S", messages: [msg])
        XCTAssertTrue(md.contains("Hello world"), md)
        XCTAssertFalse(md.contains("<p>"), md)
    }

    func testAttachmentsListed() {
        let msg = message(id: "a:1")
        let md = ThreadExporter.markdown(
            subject: "S", messages: [msg],
            attachments: [.init(messageId: "a:1", filename: "deck.pdf")])
        XCTAssertTrue(md.contains("**Attachments:**"), md)
        XCTAssertTrue(md.contains("- deck.pdf"), md)
    }

    func testSuggestedFilenameSlug() {
        let date = Date(timeIntervalSince1970: 1_720_000_000) // 2024-07-03 UTC-ish
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let name = ThreadExporter.suggestedFilename(
            subject: "Re: Q2 Board Deck!!", date: date, calendar: cal)
        XCTAssertTrue(name.hasSuffix(".md"), name)
        XCTAssertTrue(name.contains("re-q2-board-deck"), name)
        XCTAssertFalse(name.contains("!"), name)
        XCTAssertFalse(name.contains(" "), name)
    }

    func testSlugifyEmpty() {
        XCTAssertEqual(ThreadExporter.slugify(""), "")
        XCTAssertEqual(ThreadExporter.slugify("!!!"), "")
    }

    func testStripHTMLDropsScriptsAndSeparatesBlocks() {
        let html = "<div>Hi</div><script>alert(1)</script><p>There</p>"
        let plain = ThreadExporter.stripHTML(html)
        XCTAssertTrue(plain.contains("Hi"), plain)
        XCTAssertTrue(plain.contains("There"), plain)
        XCTAssertFalse(plain.contains("alert"), plain)
        // Block tags must become newlines — not glue words together.
        XCTAssertFalse(plain.contains("HiThere"), plain)
        XCTAssertTrue(plain.contains("Hi\n"), plain)
    }

    func testStripHTMLPreservesAnchorsAsMarkdown() {
        let html = #"<p>Pay here: <a href="https://pay.example/invoice/1">View invoice</a></p>"#
        let plain = ThreadExporter.stripHTML(html)
        XCTAssertTrue(plain.contains("[View invoice](https://pay.example/invoice/1)"), plain)
        XCTAssertFalse(plain.contains("<a "), plain)
    }

    func testStripHTMLAnchorWithNestedTags() {
        let html = #"<a href='https://x.test'><b>Click</b> me</a>"#
        let plain = ThreadExporter.stripHTML(html)
        XCTAssertEqual(plain, "[Click me](https://x.test)")
    }
}
