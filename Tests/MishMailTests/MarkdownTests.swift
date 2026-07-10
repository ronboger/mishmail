import XCTest

final class MarkdownTests: XCTestCase {

    // MARK: - Detection

    func testLooksLikeMarkdownDetectsCommonMarkers() {
        XCTAssertTrue(Markdown.looksLikeMarkdown("Hello **world**"))
        XCTAssertTrue(Markdown.looksLikeMarkdown("# Title\n\nBody"))
        XCTAssertTrue(Markdown.looksLikeMarkdown("See `code` here"))
        XCTAssertTrue(Markdown.looksLikeMarkdown("Math $E=mc^2$ is fun"))
        XCTAssertTrue(Markdown.looksLikeMarkdown("- one\n- two"))
        XCTAssertTrue(Markdown.looksLikeMarkdown("[link](https://example.com)"))
        XCTAssertFalse(Markdown.looksLikeMarkdown("Just a plain email.\nTwo lines."))
        XCTAssertFalse(Markdown.looksLikeMarkdown(""))
        // Single list item / money prose must not force an HTML part.
        XCTAssertFalse(Markdown.looksLikeMarkdown("- Ron"))
        XCTAssertFalse(Markdown.looksLikeMarkdown("I owe you $5 and $10 total"))
    }

    func testNestedCodeInsideBoldDoesNotLeakPlaceholders() {
        let html = Markdown.toHTML("**see `x` here**")
        XCTAssertTrue(html.contains("<strong>"), html)
        XCTAssertTrue(html.contains("<code>x</code>"), html)
        XCTAssertFalse(html.contains("\u{FFFC}"), "placeholder leaked: \(html)")
    }

    func testMoneyAmountsAreNotMath() {
        let prose = "I owe you $5 and $10 total"
        XCTAssertFalse(Markdown.looksLikeMarkdown(prose))
        // Even if forced through toHTML (e.g. mixed with other markers), no math span.
        let html = Markdown.toHTML("Thanks!\n\n" + prose)
        XCTAssertFalse(html.contains("font-family:Cambria"), html)
        XCTAssertTrue(html.contains("$5"), html)
        XCTAssertTrue(html.contains("$10"), html)
    }

    func testLiteralObjectReplacementCharIsStripped() {
        let html = Markdown.toHTML("hi \u{FFFC}1\u{FFFC} there")
        XCTAssertFalse(html.contains("\u{FFFC}"))
        XCTAssertTrue(html.contains("hi 1 there") || html.contains("hi  there"))
    }

    func testUnclosedDisplayMathDoesNotSwallowBody() {
        let html = Markdown.toHTML("$$\nno closer\n\nStill here")
        XCTAssertTrue(html.contains("Still here"), html)
        // Opening line falls through as a paragraph, not a math div for the rest.
        XCTAssertFalse(html.contains("no closer</div>"), html)
    }

    func testLinkNormalizationParity() {
        let ok = Markdown.toHTML("[x](example.com:8080)")
        XCTAssertTrue(ok.contains("href=\"https://example.com:8080\""), ok)
        // Invalid scheme stays as escaped literal text, not an anchor.
        let bad = Markdown.toHTML("[x](javascript:alert(1))")
        XCTAssertFalse(bad.contains("<a href"), bad)
        XCTAssertTrue(bad.contains("[x](javascript:alert(1))"), bad)
    }

    // MARK: - Block rendering

    func testHeadingsBoldItalicCode() {
        let html = Markdown.toHTML("""
        # Hello
        ## Sub
        This is **bold** and *italic* and `code`.
        """)
        XCTAssertTrue(html.contains("<h1>Hello</h1>"))
        XCTAssertTrue(html.contains("<h2>Sub</h2>"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<em>italic</em>"))
        XCTAssertTrue(html.contains("<code>code</code>"))
    }

    func testListsAndQuote() {
        let html = Markdown.toHTML("""
        - alpha
        - beta

        1. one
        2. two

        > quoted line
        """)
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("<li>alpha</li>"))
        XCTAssertTrue(html.contains("<ol>"))
        XCTAssertTrue(html.contains("<li>one</li>"))
        XCTAssertTrue(html.contains("<blockquote type=\"cite\">quoted line</blockquote>"))
    }

    func testFencedCodeBlock() {
        let html = Markdown.toHTML("""
        Intro

        ```swift
        let x = 1
        ```

        Outro
        """)
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">let x = 1</code></pre>"))
        XCTAssertTrue(html.contains("<p>Intro</p>"))
        XCTAssertTrue(html.contains("<p>Outro</p>"))
    }

    func testLinkAndStrikethrough() {
        let html = Markdown.toHTML("See [docs](https://a.com) and ~~old~~.")
        XCTAssertTrue(html.contains("<a href=\"https://a.com\">docs</a>"))
        XCTAssertTrue(html.contains("<del>old</del>"))
    }

    func testEscapesHTMLInPlainText() {
        let html = Markdown.toHTML("Use <script> & friends")
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("&amp; friends"))
        XCTAssertFalse(html.contains("<script>"))
    }

    // MARK: - Math

    func testInlineAndDisplayMath() {
        let inline = Markdown.toHTML("Energy $E=mc^2$ matters.")
        XCTAssertTrue(inline.contains("E=mc²") || inline.contains("E=mc"))
        XCTAssertTrue(inline.contains("font-family:Cambria"))

        let display = Markdown.toHTML("$$\\frac{a}{b}$$")
        XCTAssertTrue(display.contains("(a)/(b)"))
        XCTAssertTrue(display.contains("text-align:center"))
    }

    func testPrettyMathCommands() {
        XCTAssertEqual(Markdown.prettyMath("\\alpha + \\beta"), "α + β")
        XCTAssertEqual(Markdown.prettyMath("x^2 + y^{10}"), "x² + y¹⁰")
        XCTAssertEqual(Markdown.prettyMath("\\frac{1}{2}"), "(1)/(2)")
    }

    // MARK: - Editor helpers

    func testToggleWrapBold() {
        let (t1, s1) = Markdown.toggleWrap("hello", selection: NSRange(location: 0, length: 5),
                                           open: "**", close: "**")
        XCTAssertEqual(t1, "**hello**")
        XCTAssertEqual(s1, NSRange(location: 2, length: 5))

        let (t2, s2) = Markdown.toggleWrap(t1, selection: s1, open: "**", close: "**")
        XCTAssertEqual(t2, "hello")
        XCTAssertEqual(s2.location, 0)
        XCTAssertEqual(s2.length, 5)
    }

    func testToggleWrapEmptyInsertsMarkers() {
        let (t, s) = Markdown.toggleWrap("ab", selection: NSRange(location: 1, length: 0),
                                         open: "*", close: "*")
        XCTAssertEqual(t, "a**b")
        XCTAssertEqual(s, NSRange(location: 2, length: 0))
    }

    func testToggleLinePrefixHeading() {
        let src = "Title\nBody"
        let (t1, _) = Markdown.toggleLinePrefix(src, selection: NSRange(location: 0, length: 0),
                                                prefix: "# ")
        XCTAssertEqual(t1, "# Title\nBody")
        let (t2, _) = Markdown.toggleLinePrefix(t1, selection: NSRange(location: 0, length: 0),
                                                prefix: "# ")
        XCTAssertEqual(t2, "Title\nBody")
    }

    func testToggleLinePrefixHeadingLevelSwitch() {
        let src = "# Title"
        let (t, _) = Markdown.toggleLinePrefix(src, selection: NSRange(location: 0, length: 0),
                                               prefix: "## ")
        XCTAssertEqual(t, "## Title")
    }

    func testToggleLinePrefixEmptyLine() {
        let (t, _) = Markdown.toggleLinePrefix("", selection: NSRange(location: 0, length: 0),
                                               prefix: "# ")
        XCTAssertEqual(t, "# ")
    }

    func testToggleItalicDoesNotEatBoldMarkers() {
        let bold = "**hello**"
        // Select just "hello" (UTF-16: starts at 2, length 5).
        let (t, _) = Markdown.toggleWrap(bold, selection: NSRange(location: 2, length: 5),
                                         open: "*", close: "*")
        // Should wrap with italic, not strip one star from bold.
        XCTAssertEqual(t, "***hello***")
    }

    func testReplyQuoteStillRenders() {
        // Collapsed-quote path concatenates `> ` lines — they should become
        // a blockquote, not leak as raw text.
        let body = "Thanks!\n\n> On Mon, Ada wrote:\n> Hello"
        XCTAssertTrue(Markdown.looksLikeMarkdown(body))
        let html = Markdown.toHTML(body)
        XCTAssertTrue(html.contains("<blockquote"))
        XCTAssertTrue(html.contains("Thanks!"))
    }
}
