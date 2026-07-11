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
        // Zero-specificity exclusion via :where so JS fg classes stay (0,1,0)
        // and win by source order (Google-welcome dark-on-dark protection).
        XCTAssertTrue(css.contains(":not(:where("),
                      "inline-tag exclusion must use :where (zero specificity)")
        // Shared list — every highlighter tag excluded, not a partial hand chain.
        let tags = HTMLBodyDarkMode.inlineHighlighterTags
        XCTAssertTrue(css.contains(":not(:where(\(tags)))"),
                      "exclusion must cover full inlineHighlighterTags list")
        for tag in tags.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            XCTAssertTrue(tags.contains(tag), "sanity: \(tag) in shared list")
            XCTAssertTrue(css.contains(tag),
                          "exclusion CSS must mention tag \(tag)")
        }
    }

    /// Word / Google Docs paste wraps text in `<span style="background:white">`.
    /// Inline light fills paint per-line fragment boxes (highlighter strips);
    /// strip the paint instead of forcing dark text on the white strips.
    func testInlineLightBackgroundsAreStripped() {
        let css = HTMLBodyDarkMode.injectedCSS(fontScale: 1, collapseQuote: false)
        let strip = HTMLBodyDarkMode.stripInlineBgClass
        XCTAssertTrue(css.contains(".\(strip)") || css.contains(strip),
                      "strip-inline-bg class must be styled")
        XCTAssertTrue(css.contains("background-color: transparent !important"),
                      "inline highlighters clear the light fill")
        // Tag-based first-paint path includes span (the common Word/Docs case).
        XCTAssertTrue(css.contains(":is(span, font, mark"),
                      "first-paint strip targets common inline highlighter tags")
        // White pill CTAs: style="display:inline-block;background:#fff" must
        // not be stripped by attribute CSS (JS cannot restore !important clear).
        XCTAssertTrue(css.contains("inline-block") && css.contains("inline-flex"),
                      "first-paint strip must spare self-declared inline-block/flex CTAs")
        let js = HTMLBodyDarkMode.applyContrastJS
        XCTAssertTrue(js.contains(strip), "JS stamps strip class on inline light fills")
        XCTAssertTrue(js.contains("display") && js.contains("'inline'"),
                      "JS only strips pure display:inline (keeps inline-block CTAs)")
    }

    /// JS fg classes must remain able to beat the attribute #222 rule by source
    /// order. A high-specificity :not(span):not(font)… chain would re-break
    /// Google welcome mail (light bgcolor attr + dark computed fill).
    func testAttributeLightRuleDoesNotOutrankJSFgClasses() {
        let css = HTMLBodyDarkMode.injectedCSS(fontScale: 1, collapseQuote: false)
        // Forbidden: stacked :not(tag) that inflates specificity above (0,1,0).
        let stackedNots = css.range(
            of: #":not\(span\):not\(font\)"#,
            options: .regularExpression)
        XCTAssertNil(stackedNots,
                     "do not stack :not(tag) — use :not(:where(tags)) for zero specificity")
        XCTAssertTrue(css.contains(":not(:where("))
        // Match rule selectors only (comments also mention the class names).
        let onDark = HTMLBodyDarkMode.fgOnDarkClass
        let onLight = HTMLBodyDarkMode.fgOnLightClass
        guard let whereRange = css.range(of: ":not(:where("),
              let onDarkRule = css.range(of: ".\(onDark) {"),
              let onLightRule = css.range(of: ".\(onLight) {")
        else {
            XCTFail("missing :where exclusion or fg class rules")
            return
        }
        XCTAssertTrue(whereRange.lowerBound < onDarkRule.lowerBound,
                      ".\(onDark) rule must follow attribute rule (source-order win)")
        XCTAssertTrue(whereRange.lowerBound < onLightRule.lowerBound,
                      ".\(onLight) rule must follow attribute rule")
    }

    func testBlockLightSurfacesStillForceDarkText() {
        // Tables/divs with white bg remain designed cards — dark text, keep fill.
        let css = HTMLBodyDarkMode.injectedCSS(fontScale: 1, collapseQuote: false)
        XCTAssertTrue(css.contains("[bgcolor=\"#ffffff\" i]"))
        XCTAssertTrue(css.contains("color: #222 !important"))
        // Must not nuke every background in the message — only inline + strip class.
        XCTAssertFalse(css.contains("*, *::before"),
                       "must not nuke every background in the message")
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
        XCTAssertTrue(css.contains("#0b57d0"), "links on light surfaces use darker blue")
    }

    /// Attribute light-surface rules must be self-only. Descendant combinators
    /// forced #222 onto nested dark sections inside white wrappers (Google
    /// welcome mail: dark-on-black body + dark text on blue CTAs).
    func testAttributeLightSurfaceIsSelfOnly() {
        let css = HTMLBodyDarkMode.injectedCSS(fontScale: 1, collapseQuote: false)
        XCTAssertTrue(css.contains(":is("),
                      "attribute light surfaces still wrapped in :is()")
        // Must NOT have the old descendant force that painted dark text on
        // nested dark sections: `:is(...) :not(a):not(a *)`.
        let badDescendant = css.range(
            of: #":is\([^)]*\)\s+:not\(a\):not\(a \*\)"#,
            options: .regularExpression)
        XCTAssertNil(badDescendant,
                     "light-surface CSS must not force dark text on all descendants")
    }

    /// Effective-bg JS stamps per-node fg classes; CSS styles those classes
    /// (including light text on dark fills for nested sections).
    func testEffectiveBgForegroundClassesInCSS() {
        let onLight = HTMLBodyDarkMode.fgOnLightClass
        let onDark = HTMLBodyDarkMode.fgOnDarkClass
        let css = HTMLBodyDarkMode.injectedCSS(fontScale: 1, collapseQuote: false)
        XCTAssertTrue(css.contains(".\(onLight)"), "dark text on light effective bg")
        XCTAssertTrue(css.contains(".\(onDark)"), "light text on dark effective bg")
        XCTAssertTrue(css.contains("a.\(onLight)") || css.contains(".\(onLight):is(a)"),
                      "links on light effective bg use dark blue")
        XCTAssertTrue(css.contains("a.\(onDark)") || css.contains(".\(onDark):is(a)"),
                      "links on dark effective bg use light blue")
    }

    func testApplyContrastJSStampsBothClasses() {
        let js = HTMLBodyDarkMode.applyContrastJS
        XCTAssertTrue(js.contains(HTMLBodyDarkMode.fgOnLightClass))
        XCTAssertTrue(js.contains(HTMLBodyDarkMode.fgOnDarkClass))
        XCTAssertTrue(js.contains(HTMLBodyDarkMode.stripInlineBgClass))
        XCTAssertTrue(js.contains("getComputedStyle"))
        XCTAssertTrue(js.contains("backgroundColor"))
        // Walks with inherited effective bg (not only own fill).
        XCTAssertTrue(js.contains("inherited") || js.contains("walk"),
                      "tagger must pass effective bg down the tree")
        XCTAssertTrue(js.contains(String(HTMLBodyDarkMode.luminanceThreshold)))
        XCTAssertTrue(js.contains(String(HTMLBodyDarkMode.alphaFloor)))
        // Removes strip class before re-reading computed bg (safe re-run).
        XCTAssertTrue(js.contains("classList.remove") && js.contains("STRIP"),
                      "re-run must clear prior strip before measuring fill")
        // Alias kept for call sites.
        XCTAssertEqual(HTMLBodyDarkMode.tagLightSurfacesJS, HTMLBodyDarkMode.applyContrastJS)
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

    func testBlueCTAButtonNotLight() {
        // Google blue #1a73e8 — nested CTA on dark section must get light text,
        // not #222 / dark link blue from a white ancestor.
        XCTAssertFalse(HTMLBodyDarkMode.isLightBackground(r: 0x1a, g: 0x73, b: 0xe8))
    }

}
