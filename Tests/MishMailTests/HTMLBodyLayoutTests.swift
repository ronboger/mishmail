import XCTest

final class HTMLBodyLayoutTests: XCTestCase {
    // MARK: - Dimension caps

    func testCappedSizeNilWhenMissing() {
        XCTAssertNil(HTMLBodyLayout.cappedSize(width: nil, height: nil))
        XCTAssertNil(HTMLBodyLayout.cappedSize(width: 0, height: 0))
        XCTAssertNil(HTMLBodyLayout.cappedSize(width: -1, height: 0))
        // Non-positive on one axis is ignored; the other axis still applies.
        let hOnly = HTMLBodyLayout.cappedSize(width: -1, height: 10)
        XCTAssertNil(hOnly?.width)
        XCTAssertEqual(hOnly?.height, 10)
    }

    func testCappedSizePassthroughWithinBounds() {
        let s = HTMLBodyLayout.cappedSize(width: 180, height: 48)
        XCTAssertEqual(s?.width, 180)
        XCTAssertEqual(s?.height, 48)
    }

    func testCappedSizeClampsHugeWidthHeightProportionally() {
        // 99999×50000 → width hits 1200, height scales to 600.
        let s = HTMLBodyLayout.cappedSize(width: 99_999, height: 50_000)
        XCTAssertEqual(s?.width, HTMLBodyLayout.maxPreservedWidth)
        XCTAssertEqual(s?.height, 600)
        XCTAssertLessThanOrEqual(s!.height!, HTMLBodyLayout.maxPreservedHeight)
    }

    func testCappedSizeFitsViewportProportionally() {
        // After max-cap 1200×600, viewport 400 → 400×200 (not 400×600).
        let s = HTMLBodyLayout.cappedSize(width: 1200, height: 600,
                                          maxViewportWidth: 400)
        XCTAssertEqual(s?.width, 400)
        XCTAssertEqual(s?.height, 200)
    }

    func testCappedSizeClampsTallOnly() {
        let s = HTMLBodyLayout.cappedSize(width: 100, height: 50_000)
        XCTAssertEqual(s?.height, HTMLBodyLayout.maxPreservedHeight)
        // Width scales with height: 100 * (2000/50000) = 4.
        XCTAssertEqual(s?.width, 4)
    }

    func testCappedSizeWidthOnly() {
        let s = HTMLBodyLayout.cappedSize(width: 5_000, height: nil)
        XCTAssertEqual(s?.width, HTMLBodyLayout.maxPreservedWidth)
        XCTAssertNil(s?.height)
    }

    func testCappedSizeHeightOnly() {
        let s = HTMLBodyLayout.cappedSize(width: nil, height: 9_000)
        XCTAssertNil(s?.width)
        XCTAssertEqual(s?.height, HTMLBodyLayout.maxPreservedHeight)
    }

    func testFixtureLogoWithinCap() {
        // Logo 180×48 and spacer 1×24 from the 2FA fixture stay uncapped.
        XCTAssertEqual(HTMLBodyLayout.cappedSize(width: 180, height: 48)?.width, 180)
        XCTAssertEqual(HTMLBodyLayout.cappedSize(width: 1, height: 24)?.height, 24)
        XCTAssertEqual(HTMLBodyLayout.cappedSize(width: 552, height: 80)?.width, 552)
    }

    // MARK: - CSS / JS contracts

    func testImageCSSMentionsLayoutClasses() {
        let css = HTMLBodyLayout.imageCSS
        XCTAssertTrue(css.contains(HTMLBodyLayout.layoutImageClass))
        XCTAssertTrue(css.contains(HTMLBodyLayout.failedImageClass))
    }

    func testInjectedDarkModeCSSIncludesLayoutImageRules() {
        let css = HTMLBodyDarkMode.injectedCSS(fontScale: 1)
        XCTAssertTrue(css.contains("img { max-width: 100%; height: auto; }"))
        XCTAssertTrue(css.contains(HTMLBodyLayout.layoutImageClass))
        XCTAssertTrue(css.contains(HTMLBodyLayout.failedImageClass))
    }

    func testLayoutJSPreservesAndClearsDimensions() {
        let js = HTMLBodyLayout.installLayoutAndMeasureJS
        // Cap constants match Swift.
        XCTAssertTrue(js.contains("var MAX_W=\(HTMLBodyLayout.maxPreservedWidth)"))
        XCTAssertTrue(js.contains("var MAX_H=\(HTMLBodyLayout.maxPreservedHeight)"))
        // Blocked path stamps layout class + inline sizes.
        XCTAssertTrue(js.contains(HTMLBodyLayout.layoutImageClass))
        XCTAssertTrue(js.contains("setProperty('height'"))
        // Successful load restores author styles (snapshot), does not blindly wipe.
        XCTAssertTrue(js.contains("naturalWidth > 0"))
        XCTAssertTrue(js.contains("__mmLayoutSnap"))
        XCTAssertTrue(js.contains("snapshotProp"))
        XCTAssertTrue(js.contains("restoreProp"))
        XCTAssertTrue(js.contains("if (!snap) return"))
        // Viewport-proportional fit + reflow on resize.
        XCTAssertTrue(js.contains("fitViewport"))
        XCTAssertTrue(js.contains("reflowPlaceholders"))
        // Prefer window/documentElement over body clientWidth (fixed email body).
        XCTAssertTrue(js.contains("window.innerWidth"))
        XCTAssertTrue(js.contains("documentElement.clientWidth"))
        // Body is fallback only — not Math.max'd with viewport.
        XCTAssertFalse(js.contains("Math.max(w, document.body.clientWidth"))
        // Continuous measure: ResizeObserver + message handler + image events.
        XCTAssertTrue(js.contains("ResizeObserver"))
        XCTAssertTrue(js.contains(HTMLBodyLayout.heightHandlerName))
        XCTAssertTrue(js.contains("addEventListener('load'"))
        XCTAssertTrue(js.contains("addEventListener('error'"))
        // Still prefer visible child bottoms (no dead quote gap regression).
        XCTAssertTrue(js.contains("body.children"))
        XCTAssertTrue(js.contains("getBoundingClientRect"))
    }

    func testTeardownJSDisconnectsObserver() {
        let js = HTMLBodyLayout.teardownJS
        XCTAssertTrue(js.contains("__mmRO"))
        XCTAssertTrue(js.contains("disconnect"))
    }

    func testFixturePlainTextContainsCode() {
        // Acceptance: plain-text fallback remains accessible.
        let plain = Transactional2FAFixture.plainText
        XCTAssertTrue(plain.contains("Hello Ron"))
        XCTAssertTrue(plain.contains("119585"))
        XCTAssertFalse(plain.contains("<img"))
    }

    func testHugeImageFixtureExceedsCaps() {
        XCTAssertTrue(Transactional2FAFixture.hugeImageHTML.contains("99999"))
        let capped = HTMLBodyLayout.cappedSize(width: 99_999, height: 50_000)!
        XCTAssertLessThanOrEqual(capped.width!, HTMLBodyLayout.maxPreservedWidth)
        XCTAssertLessThanOrEqual(capped.height!, HTMLBodyLayout.maxPreservedHeight)
    }
}
