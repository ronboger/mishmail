import XCTest

final class HTMLBodyDarkModeTests: XCTestCase {
    func testPlainMailHasNoOwnBackground() {
        let html = "<div style=\"color:#000\">Hi Ron,</div><p>See you soon.</p>"
        XCTAssertFalse(HTMLBodyDarkMode.hasOwnBackground(html))
    }

    func testPureWhiteBgcolorIsOwnBackground() {
        let html = "<table bgcolor=\"#ffffff\"><tr><td>Hello</td></tr></table>"
        XCTAssertTrue(HTMLBodyDarkMode.hasOwnBackground(html))
    }

    func testCreamBackgroundColorIsOwnBackground() {
        // Constant Contact / marketing cream — the Urban Adamah failure mode.
        let html = "<td style=\"background-color:#faf8f5; color:#333\">Join us</td>"
        XCTAssertTrue(HTMLBodyDarkMode.hasOwnBackground(html))
    }

    func testBackgroundShorthandWhiteIsOwnBackground() {
        let html = "<div style=\"background: #fff; padding: 12px\">Body</div>"
        XCTAssertTrue(HTMLBodyDarkMode.hasOwnBackground(html))
    }

    func testNamedWhiteIsOwnBackground() {
        let html = "<body bgcolor=\"white\"><p>Hi</p></body>"
        XCTAssertTrue(HTMLBodyDarkMode.hasOwnBackground(html))
    }

    func testDarkBackgroundIsNotOwnLightBackground() {
        // Dark navy panel — not a light surface; keep the force-light path.
        let html = "<div style=\"background-color:#1a1a2e; color:#eee\">Banner</div>"
        XCTAssertFalse(HTMLBodyDarkMode.hasOwnBackground(html))
    }

    func testRgbHighChannelsIsOwnBackground() {
        let html = "<div style=\"background-color: rgb(250, 248, 245)\">x</div>"
        XCTAssertTrue(HTMLBodyDarkMode.hasOwnBackground(html))
    }

    func testPlainPathForcesLightTextInDarkMedia() {
        let css = HTMLBodyDarkMode.injectedCSS(fontScale: 1, collapseQuote: false,
                                               html: "<p>Hi</p>")
        XCTAssertTrue(css.contains("prefers-color-scheme: dark"))
        XCTAssertTrue(css.contains("#e6e6e6"))
        XCTAssertTrue(css.contains("color-scheme: light dark"))
    }

    func testDesignedPathLeavesAuthorColors() {
        let html = "<table bgcolor=\"#f5f0e8\"><tr><td>Newsletter</td></tr></table>"
        let css = HTMLBodyDarkMode.injectedCSS(fontScale: 1, collapseQuote: false, html: html)
        XCTAssertFalse(css.contains("prefers-color-scheme: dark"),
                       "designed mail must not force light text")
        XCTAssertFalse(css.contains("#e6e6e6"))
        XCTAssertTrue(css.contains("color-scheme: light"))
        XCTAssertTrue(css.contains("color: #222"),
                      "unstyled text needs a dark default on light panels")
    }

    func testCollapseQuoteInjectedOnBothPaths() {
        let plain = HTMLBodyDarkMode.injectedCSS(fontScale: 1, collapseQuote: true,
                                                 html: "<p>x</p>")
        let designed = HTMLBodyDarkMode.injectedCSS(
            fontScale: 1, collapseQuote: true,
            html: "<div style=\"background:#fff\">x</div>")
        XCTAssertTrue(plain.contains(QuotedReply.hideQuoteCSS)
                      || plain.contains("gmail_quote"))
        XCTAssertTrue(designed.contains(QuotedReply.hideQuoteCSS)
                      || designed.contains("gmail_quote"))
    }

    /// Plain reply whose *quoted* trail has a white table must stay on the
    /// force-light path — that was the Ron→Jeremy dark-on-dark regression.
    func testQuotedTrailWhiteBackgroundDoesNotForceDesignedPath() {
        let html = """
        <div dir="ltr">Hi Jeremy,<br><br>Wanted to flag this as well.</div>
        <div class="gmail_quote">
          <div style="background-color:#ffffff">
            <p style="color:#000">On Wed, earlier message…</p>
          </div>
        </div>
        """
        XCTAssertFalse(HTMLBodyDarkMode.hasOwnBackground(html),
                       "white bg only inside gmail_quote must be ignored")
        let css = HTMLBodyDarkMode.injectedCSS(fontScale: 1, collapseQuote: true, html: html)
        XCTAssertTrue(css.contains("#e6e6e6"),
                      "plain reply with quoted white table still forces light text")
    }

    func testAuthoredHeadCreamStillDesigned() {
        // Author's own cream panel above the quote still counts.
        let html = """
        <table bgcolor="#faf8f5"><tr><td>My note</td></tr></table>
        <div class="gmail_quote"><div>quoted</div></div>
        """
        XCTAssertTrue(HTMLBodyDarkMode.hasOwnBackground(html))
    }

    func testAuthoredHeadStripsAtGmailQuote() {
        let html = "<div>head</div><div class=\"gmail_quote\">tail white bgcolor=#ffffff</div>"
        let head = HTMLBodyDarkMode.authoredHead(of: html)
        XCTAssertTrue(head.contains("head"))
        XCTAssertFalse(head.contains("gmail_quote"))
        XCTAssertFalse(head.contains("bgcolor=#ffffff"))
    }
}
