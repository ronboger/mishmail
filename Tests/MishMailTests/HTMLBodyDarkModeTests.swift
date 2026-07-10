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

    /// Regression: multi-selector list must be wrapped in :is() so that
    /// `A, B, C :not(a)` is not parsed as only C's descendants. Urban Adamah
    /// cream tables matched early bgcolor selectors but children stayed #e6e6e6.
    func testLightSurfaceDescendantsAllGetDarkText() {
        let css = HTMLBodyDarkMode.injectedCSS(fontScale: 1, collapseQuote: false)
        XCTAssertTrue(css.contains(":is("),
                      "light-surface list must be wrapped in :is() for descendant rules")
        XCTAssertTrue(css.contains(") :not(a):not(a *)"),
                      "descendant selector must target :is(...) children")
        // Both the element and its descendants share the dark-text rule.
        XCTAssertTrue(css.contains("color: #222 !important"))
        // Ensure we didn't leave a bare "last selector only" pattern as the
        // primary light-surface rule (the old bug had no :is at all).
        let isWrappedDescendant = css.range(of: #":is\([^)]+\) :not\(a\):not\(a \*\)"#,
                                            options: .regularExpression) != nil
            || css.contains(") :not(a):not(a *)")
        XCTAssertTrue(isWrappedDescendant)
    }

    /// Notion Calendar / style-block mail: attribute selectors miss backgrounds
    /// declared only in `<style>`. CSS must style the computed-tag class, and
    /// the tagger JS must stamp that class from getComputedStyle.
    func testComputedLightSurfaceClassInCSS() {
        let cls = HTMLBodyDarkMode.lightSurfaceClass
        let css = HTMLBodyDarkMode.injectedCSS(fontScale: 1, collapseQuote: false)
        XCTAssertTrue(css.contains(".\(cls)"),
                      "CSS must target .\(cls) stamped by post-load JS")
        XCTAssertTrue(css.contains(".\(cls) :not(a):not(a *)"),
                      "descendants of computed light surfaces get dark text")
        XCTAssertTrue(css.contains(".\(cls) a"),
                      "links inside computed light surfaces use dark blue")
    }

    func testTagLightSurfacesJSStampsClass() {
        let cls = HTMLBodyDarkMode.lightSurfaceClass
        let js = HTMLBodyDarkMode.tagLightSurfacesJS
        XCTAssertTrue(js.contains(cls), "tagger must stamp \(cls)")
        XCTAssertTrue(js.contains("getComputedStyle"),
                      "tagger must use computed styles, not attributes")
        XCTAssertTrue(js.contains("classList.add"),
                      "tagger must add the light-surface class")
        XCTAssertTrue(js.contains("backgroundColor"),
                      "tagger reads backgroundColor")
        // JS thresholds must match the Swift constants (no drift).
        XCTAssertTrue(js.contains(String(HTMLBodyDarkMode.luminanceThreshold)),
                      "JS embeds luminanceThreshold")
        XCTAssertTrue(js.contains(String(HTMLBodyDarkMode.alphaFloor)),
                      "JS embeds alphaFloor")
    }

    // MARK: - isLightBackground thresholds

    func testWhiteIsLight() {
        XCTAssertTrue(HTMLBodyDarkMode.isLightBackground(r: 255, g: 255, b: 255))
    }

    func testCreamIsLight() {
        // #faf8f5 — Urban Adamah / common newsletter cream
        XCTAssertTrue(HTMLBodyDarkMode.isLightBackground(r: 0xfa, g: 0xf8, b: 0xf5))
    }

    func testNearThresholdLuminance() {
        // Synthetic grays around luminanceThreshold (0.72).
        // L = gray/255; gray > 0.72*255 ≈ 183.6 → light.
        XCTAssertFalse(HTMLBodyDarkMode.isLightBackground(r: 183, g: 183, b: 183),
                       "just under threshold must stay untagged")
        XCTAssertTrue(HTMLBodyDarkMode.isLightBackground(r: 184, g: 184, b: 184),
                      "just over threshold must tag")
    }

    func testAlphaFloor() {
        XCTAssertFalse(HTMLBodyDarkMode.isLightBackground(r: 255, g: 255, b: 255, a: 0.49),
                       "mostly transparent white is not a light surface")
        XCTAssertTrue(HTMLBodyDarkMode.isLightBackground(r: 255, g: 255, b: 255, a: 0.5))
        XCTAssertFalse(HTMLBodyDarkMode.isLightBackground(r: 255, g: 255, b: 255, a: 0),
                       "fully transparent never tags")
    }

    func testDarkChromeColorsNotLight() {
        XCTAssertFalse(HTMLBodyDarkMode.isLightBackground(r: 0x1a, g: 0x1a, b: 0x2e))
        XCTAssertFalse(HTMLBodyDarkMode.isLightBackground(r: 0x22, g: 0x22, b: 0x22))
        XCTAssertFalse(HTMLBodyDarkMode.isLightBackground(r: 0, g: 0, b: 0))
    }

}
