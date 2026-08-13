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

    func testApplyLinkPercentEncodesParensInHref() {
        // A raw ")" in the href would end the markdown link early when
        // re-parsed, so parens must be percent-encoded.
        let body = "see docs now"
        let r = body.range(of: "docs")!
        let out = ComposeLinks.applyLink(in: body, selection: r,
                                         url: "https://foo.com/path(1)")
        XCTAssertEqual(out, "see [docs](https://foo.com/path%281%29) now")
        let links = ComposeLinks.markdownLinks(in: out!)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.url, "https://foo.com/path%281%29")
    }

    func testApplyLinkParenWrappedSelectionRoundTrips() {
        // ⌘K on "(foo.com)": selfLink trims to the URL, applyLink keeps the
        // parens in the label, and the result re-parses as one clean link.
        let body = "(foo.com)"
        let all = body.startIndex..<body.endIndex
        guard let href = ComposeLinks.selfLink(forSelection: body) else {
            return XCTFail("expected selfLink")
        }
        let out = ComposeLinks.applyLink(in: body, selection: all,
                                         text: body, url: href)
        XCTAssertEqual(out, "[(foo.com)](https://foo.com)")
        let links = ComposeLinks.markdownLinks(in: out!)
        XCTAssertEqual(links.first?.url, "https://foo.com")
        XCTAssertEqual(links.first?.text, "(foo.com)")
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
                       "read <a href=\"https://example.com/a\" dir=\"ltr\">the docs</a>")
    }

    func testHTMLNormalizesBareHostInMarkdown() {
        // Hand-typed markdown without a scheme must not emit a relative href.
        let html = ComposeLinks.htmlFragment(from: "[x](example.com)")
        XCTAssertEqual(html, "<a href=\"https://example.com\" dir=\"ltr\">x</a>")
    }

    func testHTMLAutolinksBareHTTPS() {
        let html = ComposeLinks.htmlFragment(from: "go https://example.com/x now")
        XCTAssertEqual(html,
                       "go <a href=\"https://example.com/x\" dir=\"ltr\">https://example.com/x</a> now")
    }

    func testHTMLAutolinkTrimsTrailingPunctuation() {
        let html = ComposeLinks.htmlFragment(from: "see https://example.com/x.")
        XCTAssertEqual(html,
                       "see <a href=\"https://example.com/x\" dir=\"ltr\">https://example.com/x</a>.")
    }

    func testHTMLAutolinkTrimsTrailingParen() {
        let html = ComposeLinks.htmlFragment(from: "see https://example.com/x)")
        XCTAssertEqual(html,
                       "see <a href=\"https://example.com/x\" dir=\"ltr\">https://example.com/x</a>)")
    }

    func testHTMLDoesNotDoubleLinkMarkdown() {
        // Bare-URL pass must not re-wrap the href already inside [text](url).
        let html = ComposeLinks.htmlFragment(from: "[x](https://example.com)")
        XCTAssertEqual(html, "<a href=\"https://example.com\" dir=\"ltr\">x</a>")
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
        XCTAssertEqual(html, "café <a href=\"https://example.com\" dir=\"ltr\">docs</a>")
    }

    // MARK: - selfLink

    func testSelfLinkAcceptsHTTPS() {
        XCTAssertEqual(ComposeLinks.selfLink(forSelection: "https://example.com/a"),
                       "https://example.com/a")
    }

    func testSelfLinkAcceptsHTTP() {
        XCTAssertEqual(ComposeLinks.selfLink(forSelection: "http://example.com"),
                       "http://example.com")
    }

    func testSelfLinkAcceptsBareHost() {
        XCTAssertEqual(ComposeLinks.selfLink(forSelection: "foo.com"),
                       "https://foo.com")
    }

    func testSelfLinkAcceptsBareEmail() {
        XCTAssertEqual(ComposeLinks.selfLink(forSelection: "a@b.com"),
                       "mailto:a@b.com")
    }

    func testSelfLinkAcceptsMailtoScheme() {
        XCTAssertEqual(ComposeLinks.selfLink(forSelection: "mailto:a@b.com"),
                       "mailto:a@b.com")
    }

    func testSelfLinkAcceptsTrimmedWhitespace() {
        XCTAssertEqual(ComposeLinks.selfLink(forSelection: "  foo.com  "),
                       "https://foo.com")
    }

    func testSelfLinkTrimsTrailingDot() {
        XCTAssertEqual(ComposeLinks.selfLink(forSelection: "foo.com."),
                       "https://foo.com")
    }

    func testSelfLinkTrimsTrailingComma() {
        XCTAssertEqual(ComposeLinks.selfLink(forSelection: "foo.com,"),
                       "https://foo.com")
    }

    func testSelfLinkStripsWrappingParens() {
        XCTAssertEqual(ComposeLinks.selfLink(forSelection: "(foo.com)"),
                       "https://foo.com")
    }

    func testSelfLinkKeepsBalancedParensInPath() {
        XCTAssertEqual(ComposeLinks.selfLink(forSelection: "https://foo.com/path(1)"),
                       "https://foo.com/path(1)")
    }

    func testSelfLinkRejectsPunctuationOnlySelection() {
        XCTAssertNil(ComposeLinks.selfLink(forSelection: "()"))
        XCTAssertNil(ComposeLinks.selfLink(forSelection: "..."))
    }

    func testSelfLinkRejectsPlainWord() {
        // normalizeURL would happily turn "hello" into "https://hello" —
        // selfLink must not, since it doesn't plausibly look like a URL.
        XCTAssertNil(ComposeLinks.selfLink(forSelection: "hello"))
    }

    func testSelfLinkRejectsMultiWordSelection() {
        XCTAssertNil(ComposeLinks.selfLink(forSelection: "click foo.com"))
        XCTAssertNil(ComposeLinks.selfLink(forSelection: "foo.com\nbar.com"))
    }

    func testSelfLinkRejectsDangerousSchemes() {
        XCTAssertNil(ComposeLinks.selfLink(forSelection: "javascript:alert(1)"))
        XCTAssertNil(ComposeLinks.selfLink(forSelection: "data:text/html,hi"))
    }

    func testSelfLinkRejectsTextAlreadyInsideMarkdownLink() {
        XCTAssertNil(ComposeLinks.selfLink(forSelection: "[foo.com](https://foo.com)"))
    }

    func testSelfLinkRejectsEmptyAndWhitespaceOnly() {
        XCTAssertNil(ComposeLinks.selfLink(forSelection: ""))
        XCTAssertNil(ComposeLinks.selfLink(forSelection: "   "))
    }

    // MARK: - editorLinkStyleRanges (blue without [url](url))

    func testEditorLinkStyleRangesIncludesBareHost() {
        // Bare hosts that auto-link on send must paint blue in the editor
        // without wrapping as [url](url).
        let body = "see foo.com now"
        let ranges = ComposeLinks.editorLinkStyleRanges(in: body)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual((body as NSString).substring(with: ranges[0]), "foo.com")
    }

    func testEditorLinkStyleRangesIncludesHTTPS() {
        let body = "go https://example.com/a please"
        let ranges = ComposeLinks.editorLinkStyleRanges(in: body)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual((body as NSString).substring(with: ranges[0]),
                       "https://example.com/a")
    }

    func testEditorLinkStyleRangesIncludesMarkdownLink() {
        let body = "read [the docs](https://example.com/a)"
        let ranges = ComposeLinks.editorLinkStyleRanges(in: body)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual((body as NSString).substring(with: ranges[0]),
                       "the docs")
    }

    func testEditorLinkStyleRangesDoesNotDoubleCountMarkdownHref() {
        // Bare-URL pass must not also style the href inside [text](url).
        let body = "[x](https://example.com)"
        let ranges = ComposeLinks.editorLinkStyleRanges(in: body)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual((body as NSString).substring(with: ranges[0]),
                       "x")
    }

    func testEditorPresentationConcealsMarkdownSyntaxAndDestination() {
        let body = "read [the docs](https://example.com/a) now"
        let presentations = ComposeLinks.editorPresentations(in: body)
        XCTAssertEqual(presentations.count, 1)
        let presentation = presentations[0]
        XCTAssertEqual((body as NSString).substring(with: presentation.visibleRange),
                       "the docs")
        XCTAssertEqual(presentation.concealedRanges.map {
            (body as NSString).substring(with: $0)
        }, ["[", "](https://example.com/a)"])
    }

    func testEditorPresentationLeavesBareURLFullyVisible() {
        let body = "go https://example.com/a now"
        let presentation = ComposeLinks.editorPresentations(in: body)[0]
        XCTAssertEqual((body as NSString).substring(with: presentation.visibleRange),
                       "https://example.com/a")
        XCTAssertTrue(presentation.concealedRanges.isEmpty)
    }

    func testEditorPresentationHandlesMultipleLinksWithoutHrefDoubleCount() {
        let body = "[one](https://one.com) and two.com"
        let presentations = ComposeLinks.editorPresentations(in: body)
        XCTAssertEqual(presentations.map {
            (body as NSString).substring(with: $0.visibleRange)
        }, ["one", "two.com"])
        XCTAssertEqual(presentations[0].concealedRanges.count, 2)
        XCTAssertTrue(presentations[1].concealedRanges.isEmpty)
    }

    func testEditorLinkStyleRangesSkipsPlainWords() {
        XCTAssertTrue(ComposeLinks.editorLinkStyleRanges(in: "hello world").isEmpty)
    }

    func testEditorLinkStyleRangesSkipsNonLinkableHost() {
        // setup.sh is isolated for BiDi but not autolinked — no blue.
        XCTAssertTrue(ComposeLinks.editorLinkStyleRanges(in: "run setup.sh now").isEmpty)
    }

    // MARK: - bareURLCmdK (⌘K on bare URL — no sheet)

    func testBareURLCmdKAlreadyLinkedHost() {
        // foo.com already auto-links + paints blue → no sheet, no [url](url).
        let body = "see foo.com now"
        let r = body.range(of: "foo.com")!
        XCTAssertEqual(ComposeLinks.bareURLCmdK(in: body, selection: r), .alreadyLinked)
        XCTAssertTrue(ComposeLinks.isAutolinkBareSelection("foo.com"))
    }

    func testBareURLCmdKAlreadyLinkedHTTPS() {
        let body = "go https://example.com/a please"
        let r = body.range(of: "https://example.com/a")!
        XCTAssertEqual(ComposeLinks.bareURLCmdK(in: body, selection: r), .alreadyLinked)
        XCTAssertTrue(ComposeLinks.isAutolinkBareSelection("https://example.com/a"))
    }

    func testBareURLCmdKWrapsBareEmail() {
        // Bare emails do not auto-link as plain text — wrap so they become
        // a real (blue) mailto link, still without opening the sheet.
        let body = "mail a@b.com today"
        let r = body.range(of: "a@b.com")!
        XCTAssertFalse(ComposeLinks.isAutolinkBareSelection("a@b.com"))
        XCTAssertEqual(ComposeLinks.bareURLCmdK(in: body, selection: r),
                       .wrap("mail [a@b.com](mailto:a@b.com) today"))
    }

    func testBareURLCmdKWrapsParenWrappedHost() {
        let body = "(foo.com)"
        let all = body.startIndex..<body.endIndex
        XCTAssertEqual(ComposeLinks.bareURLCmdK(in: body, selection: all),
                       .wrap("[(foo.com)](https://foo.com)"))
    }

    func testBareURLCmdKNilForPlainWord() {
        let body = "hello world"
        let r = body.range(of: "hello")!
        XCTAssertNil(ComposeLinks.bareURLCmdK(in: body, selection: r))
    }

    func testBareURLCmdKNilForExistingMarkdown() {
        let body = "[foo.com](https://foo.com)"
        let all = body.startIndex..<body.endIndex
        XCTAssertNil(ComposeLinks.bareURLCmdK(in: body, selection: all))
    }

    // MARK: - shouldWrap (bare URL ⌘K)

    func testShouldWrapEmptyLabelIsFalse() {
        // Empty display text → leave bare URL alone (auto-links on send).
        XCTAssertFalse(ComposeLinks.shouldWrap(label: "", href: "https://x.com/foo"))
        XCTAssertFalse(ComposeLinks.shouldWrap(label: "   ", href: "https://x.com/foo"))
    }

    func testShouldWrapLabelEqualToURLIsFalse() {
        XCTAssertFalse(ComposeLinks.shouldWrap(
            label: "https://x.com/foo", href: "https://x.com/foo"))
        // Bare host normalizes to the same href as the selection.
        XCTAssertFalse(ComposeLinks.shouldWrap(
            label: "x.com/foo", href: "https://x.com/foo"))
        XCTAssertFalse(ComposeLinks.shouldWrap(
            label: "a@b.com", href: "mailto:a@b.com"))
    }

    func testShouldWrapDistinctLabelIsTrue() {
        XCTAssertTrue(ComposeLinks.shouldWrap(
            label: "docs", href: "https://x.com/foo"))
        XCTAssertTrue(ComposeLinks.shouldWrap(
            label: "click here", href: "https://example.com"))
    }

    // MARK: - bareURLApply (bare URL ⌘K apply decision)

    func testBareURLApplyEmptyLabelSameURLIsNoOp() {
        let existing = "https://x.com/foo"
        XCTAssertEqual(
            ComposeLinks.bareURLApply(label: "", href: existing, existingHref: existing),
            .noOp)
        XCTAssertEqual(
            ComposeLinks.bareURLApply(label: "   ", href: "x.com/foo",
                                      existingHref: existing),
            .noOp)
    }

    func testBareURLApplyEmptyLabelChangedURLReplacesBare() {
        let existing = "https://x.com/foo"
        XCTAssertEqual(
            ComposeLinks.bareURLApply(label: "", href: "https://y.com/bar",
                                      existingHref: existing),
            .replaceBare("https://y.com/bar"))
        // Bare host input normalizes before replace.
        XCTAssertEqual(
            ComposeLinks.bareURLApply(label: "", href: "y.com/bar",
                                      existingHref: existing),
            .replaceBare("https://y.com/bar"))
    }

    func testBareURLApplyLabelEqualToURLIsNoOp() {
        let existing = "https://x.com/foo"
        XCTAssertEqual(
            ComposeLinks.bareURLApply(label: "https://x.com/foo", href: existing,
                                      existingHref: existing),
            .noOp)
        XCTAssertEqual(
            ComposeLinks.bareURLApply(label: "x.com/foo", href: existing,
                                      existingHref: existing),
            .noOp)
    }

    func testBareURLApplyDistinctLabelWraps() {
        let existing = "https://x.com/foo"
        XCTAssertEqual(
            ComposeLinks.bareURLApply(label: "docs", href: existing,
                                      existingHref: existing),
            .wrap)
        XCTAssertEqual(
            ComposeLinks.bareURLApply(label: "click here", href: "https://y.com",
                                      existingHref: existing),
            .wrap)
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
