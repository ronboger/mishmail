import XCTest

final class ComposeLinksTests: XCTestCase {

    // MARK: - normalizeURL

    func testNormalizeHTTPSPassthrough() {
        XCTAssertEqual(ComposeLinks.normalizeURL("https://example.com/a"),
                       "https://example.com/a")
    }

    func testNormalizeHTTPPassthrough() {
        XCTAssertEqual(ComposeLinks.normalizeURL("http://example.com"),
                       "http://example.com")
    }

    func testNormalizeMailtoPassthrough() {
        XCTAssertEqual(ComposeLinks.normalizeURL("mailto:a@b.com"),
                       "mailto:a@b.com")
    }

    func testNormalizeBareHostGetsHTTPS() {
        XCTAssertEqual(ComposeLinks.normalizeURL("example.com/path"),
                       "https://example.com/path")
    }

    func testNormalizeHostPortGetsHTTPS() {
        // Colon is port, not a scheme separator — must not reject.
        XCTAssertEqual(ComposeLinks.normalizeURL("example.com:8080/dash"),
                       "https://example.com:8080/dash")
    }

    func testNormalizePathWithColonGetsHTTPS() {
        XCTAssertEqual(ComposeLinks.normalizeURL("example.com/a:b"),
                       "https://example.com/a:b")
    }

    func testNormalizeBareEmailGetsMailto() {
        XCTAssertEqual(ComposeLinks.normalizeURL("a@b.com"),
                       "mailto:a@b.com")
    }

    func testNormalizeStripsAngleBrackets() {
        XCTAssertEqual(ComposeLinks.normalizeURL("<https://x.com>"),
                       "https://x.com")
    }

    func testNormalizeRejectsEmptyAndDangerousSchemes() {
        XCTAssertNil(ComposeLinks.normalizeURL(""))
        XCTAssertNil(ComposeLinks.normalizeURL("   "))
        XCTAssertNil(ComposeLinks.normalizeURL("javascript:alert(1)"))
        XCTAssertNil(ComposeLinks.normalizeURL("data:text/html,hi"))
        XCTAssertNil(ComposeLinks.normalizeURL("file:///etc/passwd"))
        XCTAssertNil(ComposeLinks.normalizeURL("mailto:"))  // empty address
    }

    // MARK: - apply / remove / find

    func testApplyLinkAroundSelection() {
        let body = "please click here today"
        let start = body.range(of: "click here")!
        let out = ComposeLinks.applyLink(in: body, selection: start,
                                         url: "https://example.com")
        XCTAssertEqual(out, "please [click here](https://example.com) today")
    }

    func testApplyLinkEmptySelectionUsesURLAsLabel() {
        let body = "go: "
        let end = body.endIndex
        let out = ComposeLinks.applyLink(in: body, selection: end..<end,
                                         url: "example.com")
        XCTAssertEqual(out, "go: [https://example.com](https://example.com)")
    }

    func testApplyLinkExplicitTextOverridesSelection() {
        let body = "xxx"
        let all = body.startIndex..<body.endIndex
        let out = ComposeLinks.applyLink(in: body, selection: all,
                                         text: "docs", url: "https://x.test")
        XCTAssertEqual(out, "[docs](https://x.test)")
    }

    func testApplyLinkRejectsBadURL() {
        let body = "hi"
        XCTAssertNil(ComposeLinks.applyLink(
            in: body, selection: body.startIndex..<body.endIndex,
            url: "javascript:alert(1)"))
    }

    func testLinkAtFindsMarkdownLink() {
        let body = "see [docs](https://x.test) please"
        guard let r = body.range(of: "docs") else { return XCTFail("range") }
        let hit = ComposeLinks.link(at: r.lowerBound, in: body)
        XCTAssertEqual(hit?.text, "docs")
        XCTAssertEqual(hit?.url, "https://x.test")
    }

    func testRemoveLinkLeavesLabel() {
        let body = "see [docs](https://x.test) please"
        guard let hit = ComposeLinks.link(at: body.range(of: "docs")!.lowerBound,
                                          in: body) else {
            return XCTFail("expected link")
        }
        XCTAssertEqual(ComposeLinks.removeLink(hit, in: body), "see docs please")
    }

    // MARK: - htmlFragment

    func testHTMLEscapesPlainTextAndNewlines() {
        let html = ComposeLinks.htmlFragment(from: "See <b>below</b> & enjoy\nsecond line")
        XCTAssertEqual(html, "See &lt;b&gt;below&lt;/b&gt; &amp; enjoy<br>second line")
    }

    func testHTMLConvertsMarkdownLink() {
        let html = ComposeLinks.htmlFragment(from: "read [the docs](https://example.com/a)")
        XCTAssertEqual(html,
                       "read <a href=\"https://example.com/a\">the docs</a>")
    }

    func testHTMLNormalizesBareHostInMarkdown() {
        // Hand-typed markdown without a scheme must not emit a relative href.
        let html = ComposeLinks.htmlFragment(from: "[x](example.com)")
        XCTAssertEqual(html, "<a href=\"https://example.com\">x</a>")
    }

    func testHTMLAutolinksBareHTTPS() {
        let html = ComposeLinks.htmlFragment(from: "go https://example.com/x now")
        XCTAssertEqual(html,
                       "go <a href=\"https://example.com/x\">https://example.com/x</a> now")
    }

    func testHTMLAutolinkTrimsTrailingPunctuation() {
        let html = ComposeLinks.htmlFragment(from: "see https://example.com/x.")
        XCTAssertEqual(html,
                       "see <a href=\"https://example.com/x\">https://example.com/x</a>.")
    }

    func testHTMLAutolinkTrimsTrailingParen() {
        let html = ComposeLinks.htmlFragment(from: "see https://example.com/x)")
        XCTAssertEqual(html,
                       "see <a href=\"https://example.com/x\">https://example.com/x</a>)")
    }

    func testHTMLDoesNotDoubleLinkMarkdown() {
        // Bare-URL pass must not re-wrap the href already inside [text](url).
        let html = ComposeLinks.htmlFragment(from: "[x](https://example.com)")
        XCTAssertEqual(html, "<a href=\"https://example.com\">x</a>")
        XCTAssertFalse(html.contains("<a href=\"https://example.com\"><a"))
    }

    func testHTMLEscapesAttributeQuotes() {
        // Pathological but legal after normalize; quotes in href must be escaped.
        let html = ComposeLinks.htmlFragment(from: #"[a](https://x.com/"y")"#)
        XCTAssertTrue(html.contains("href=\"https://x.com/&quot;y&quot;\""))
    }

    func testHTMLEmptyBody() {
        XCTAssertEqual(ComposeLinks.htmlFragment(from: ""), "")
    }

    func testHTMLRejectsJavascriptMarkdown() {
        // Disallowed schemes are left as literal text (escaped), not anchors.
        let html = ComposeLinks.htmlFragment(from: "[x](javascript:alert(1))")
        XCTAssertFalse(html.contains("<a "))
        XCTAssertTrue(html.contains("javascript:alert(1)"))
    }

    func testHTMLUnicodeAroundLink() {
        let html = ComposeLinks.htmlFragment(from: "café [docs](https://example.com)")
        XCTAssertEqual(html, "café <a href=\"https://example.com\">docs</a>")
    }

    // MARK: - UTF-16 bridge

    func testNSRangeRoundTrip() {
        let s = "café [link](https://x.com)"
        guard let r = s.range(of: "link") else { return XCTFail("range") }
        let ns = ComposeLinks.nsRange(of: r, in: s)
        let back = ComposeLinks.stringRange(nsRange: ns, in: s)
        XCTAssertEqual(back, r)
    }
}
