import XCTest

final class ForwardComposerTests: XCTestCase {

    private let date = Date(timeIntervalSince1970: 1_760_000_000)

    private func block(cc: String = "", bodyText: String = "Hello\nWorld") -> String {
        ForwardComposer.forwardBlock(
            fromHeader: "Jane Doe <jane@x.com>", date: date,
            subject: "Quarterly report", toHeader: "ron@x.com",
            ccHeader: cc, bodyText: bodyText)
    }

    func testForwardBlockContainsHeadersAndBody() {
        let b = block()
        XCTAssertTrue(b.contains(ForwardComposer.marker))
        XCTAssertTrue(b.contains("From: Jane Doe <jane@x.com>"))
        XCTAssertTrue(b.contains("Subject: Quarterly report"))
        XCTAssertTrue(b.contains("To: ron@x.com"))
        XCTAssertTrue(b.contains("Date: "))
        XCTAssertFalse(b.contains("Cc: "))
        XCTAssertTrue(b.hasSuffix("Hello\nWorld"))
    }

    func testForwardBlockIncludesCcWhenPresent() {
        XCTAssertTrue(block(cc: "bob@x.com").contains("Cc: bob@x.com"))
    }

    func testForwardBlockIsDeterministic() {
        // Send-time HTML upgrading depends on recomputing the identical block.
        XCTAssertEqual(block(), block())
    }

    func testUserTextExtractedWhenQuotedTailUntouched() {
        let b = block()
        let body = "Please see below.\n\n" + b
        XCTAssertEqual(ForwardComposer.userText(inBody: body, expectedBlock: b),
                       "Please see below.")
    }

    func testUserTextEmptyWhenNothingTyped() {
        let b = block()
        XCTAssertEqual(ForwardComposer.userText(inBody: "\n\n" + b, expectedBlock: b), "")
    }

    func testUserTextNilWhenQuotedTailEdited() {
        let b = block()
        let edited = ("note above\n\n" + b).replacingOccurrences(of: "World", with: "Wörld")
        XCTAssertNil(ForwardComposer.userText(inBody: edited, expectedBlock: b))
    }

    func testUserTextNilWhenBlockDeleted() {
        XCTAssertNil(ForwardComposer.userText(inBody: "just my own text",
                                              expectedBlock: block()))
    }

    func testHTMLBodyEscapesUserTextAndKeepsOriginalHTML() {
        let html = ForwardComposer.htmlBody(
            userText: "See <b>below</b> & enjoy\nsecond line",
            fromHeader: "Jane <jane@x.com>", date: date,
            subject: "A & B", toHeader: "ron@x.com", ccHeader: "",
            originalHTML: "<div style=\"color:red\">Rich <b>content</b></div>")
        // User text is escaped, not interpreted.
        XCTAssertTrue(html.contains("See &lt;b&gt;below&lt;/b&gt; &amp; enjoy<br>second line"))
        // Original markup survives verbatim.
        XCTAssertTrue(html.contains("<div style=\"color:red\">Rich <b>content</b></div>"))
        // Header block present and escaped.
        XCTAssertTrue(html.contains(ForwardComposer.marker))
        XCTAssertTrue(html.contains("Jane &lt;jane@x.com&gt;"))
        XCTAssertTrue(html.contains("A &amp; B"))
    }
}
