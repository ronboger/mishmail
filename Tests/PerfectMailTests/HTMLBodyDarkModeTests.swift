import XCTest

final class HTMLBodyDarkModeTests: XCTestCase {
    func testPlainMailForcesLightText() {
        let css = HTMLBodyDarkMode.injectedCSS(fontScale: 1, collapseQuote: false,
                                               html: "<p style=\"color:#000\">Hi</p>")
        XCTAssertTrue(css.contains("prefers-color-scheme: dark"))
        XCTAssertTrue(css.contains("#e6e6e6"))
    }

    func testLightSurfacesForceDarkText() {
        let css = HTMLBodyDarkMode.injectedCSS(fontScale: 1, collapseQuote: false, html: "")
        // White bgcolor panels get dark text (signature cards).
        XCTAssertTrue(css.contains("[bgcolor=\"#ffffff\" i]"))
        XCTAssertTrue(css.contains("color: #222 !important"))
        // Light hex first-nibble coverage for cream newsletters.
        XCTAssertTrue(css.contains("[bgcolor^=\"#f\" i]"))
    }

    func testAshleyStyleMixedMailHasBothRules() {
        // Body has no bg; signature table is white — both force-light and
        // light-surface dark text must be present so mixed mail works.
        let html = """
        <div>Hi Ron,</div>
        <div class="front-signature">
          <table bgcolor="#ffffff"><tr><td style="color: rgb(147, 147, 147)">Ashley</td></tr></table>
        </div>
        <blockquote type="cite">earlier</blockquote>
        """
        let css = HTMLBodyDarkMode.injectedCSS(fontScale: 1, collapseQuote: true, html: html)
        XCTAssertTrue(css.contains("#e6e6e6"))
        XCTAssertTrue(css.contains("#222"))
        XCTAssertTrue(HTMLBodyDarkMode.hasOwnBackground(html),
                      "white sig in authored head still detectable")
    }

    func testQuotedTrailWhiteBackgroundDetectionIgnored() {
        let html = """
        <div dir="ltr">Hi Jeremy,</div>
        <div class="gmail_quote">
          <div style="background-color:#ffffff"><p>quoted</p></div>
        </div>
        """
        XCTAssertFalse(HTMLBodyDarkMode.hasOwnBackground(html))
    }

    func testCreamDetection() {
        let html = "<td style=\"background-color:#faf8f5; color:#333\">Join us</td>"
        XCTAssertTrue(HTMLBodyDarkMode.hasOwnBackground(html))
    }

    func testPlainHasNoOwnBackground() {
        let html = "<div style=\"color:#000\">Hi Ron,</div>"
        XCTAssertFalse(HTMLBodyDarkMode.hasOwnBackground(html))
    }

    func testDarkBackgroundNotOwnLight() {
        let html = "<div style=\"background-color:#1a1a2e; color:#eee\">Banner</div>"
        XCTAssertFalse(HTMLBodyDarkMode.hasOwnBackground(html))
    }

    func testCollapseQuoteInjected() {
        let css = HTMLBodyDarkMode.injectedCSS(fontScale: 1, collapseQuote: true, html: "<p>x</p>")
        XCTAssertTrue(css.contains(QuotedReply.hideQuoteCSS) || css.contains("gmail_quote"))
    }

    func testAuthoredHeadStripsAtGmailQuote() {
        let html = "<div>head</div><div class=\"gmail_quote\">tail white bgcolor=#ffffff</div>"
        let head = HTMLBodyDarkMode.authoredHead(of: html)
        XCTAssertTrue(head.contains("head"))
        XCTAssertFalse(head.contains("gmail_quote"))
    }

    func testLinksStayBlueOutsideLightSurfaces() {
        let css = HTMLBodyDarkMode.injectedCSS(fontScale: 1, collapseQuote: false)
        XCTAssertTrue(css.contains("#6cb2ff"))
        XCTAssertTrue(css.contains("#0b57d0"), "links inside light surfaces use darker blue")
    }
}
