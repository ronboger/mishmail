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
