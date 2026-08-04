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

    // MARK: - Content height clamp

    func testClampContentHeightFloorsAndCaps() {
        XCTAssertEqual(HTMLBodyLayout.clampContentHeight(0),
                       CGFloat(HTMLBodyLayout.minContentHeight))
        XCTAssertEqual(HTMLBodyLayout.clampContentHeight(-10),
                       CGFloat(HTMLBodyLayout.minContentHeight))
        XCTAssertEqual(HTMLBodyLayout.clampContentHeight(480), 480)
        XCTAssertEqual(HTMLBodyLayout.clampContentHeight(CGFloat(HTMLBodyLayout.maxContentHeight + 1)),
                       CGFloat(HTMLBodyLayout.maxContentHeight))
        XCTAssertEqual(HTMLBodyLayout.clampContentHeight(.infinity),
                       CGFloat(HTMLBodyLayout.minContentHeight))
        XCTAssertEqual(HTMLBodyLayout.clampContentHeight(.nan),
                       CGFloat(HTMLBodyLayout.minContentHeight))
    }

    // MARK: - Feedback freeze (pure state machine)

    func testIsFeedbackGrowthTracksViewportDelta() {
        // Content +50 while viewport +50 → feedback.
        XCTAssertTrue(HTMLBodyLayout.isFeedbackGrowth(
            previousHeight: 400, previousViewport: 400,
            height: 450, viewport: 450))
        // Content flat while viewport grows → not feedback.
        XCTAssertFalse(HTMLBodyLayout.isFeedbackGrowth(
            previousHeight: 400, previousViewport: 400,
            height: 400, viewport: 450))
        // Real content growth (much more than viewport) → not feedback.
        XCTAssertFalse(HTMLBodyLayout.isFeedbackGrowth(
            previousHeight: 400, previousViewport: 400,
            height: 900, viewport: 420))
        // Missing prior samples → not feedback.
        XCTAssertFalse(HTMLBodyLayout.isFeedbackGrowth(
            previousHeight: 0, previousViewport: 400,
            height: 450, viewport: 450))
    }

    func testObserveFeedbackRequiresConsecutiveHitsBeforeFreeze() {
        // Hit 1: record streak base, no freeze yet — even when base is already
        // within tolerance of the viewport (would pass the below-viewport guard).
        let s1 = HTMLBodyLayout.observeFeedback(
            previousHeight: 800, previousViewport: 800,
            height: 805, viewport: 804,
            consecutiveHits: 0, streakBaseHeight: nil)
        XCTAssertEqual(s1.consecutiveHits, 1)
        XCTAssertEqual(s1.streakBaseHeight, 800)
        XCTAssertNil(s1.freezeAt)

        // Hit 2: freeze at pre-streak height when base + tol >= current viewport.
        // (A second large growth step would push viewport past base+tol and the
        // below-viewport guard would block; freeze still requires consecutive hits.)
        let s2 = HTMLBodyLayout.observeFeedback(
            previousHeight: 800, previousViewport: 800,
            height: 805, viewport: 804,
            consecutiveHits: 1, streakBaseHeight: 800)
        XCTAssertEqual(s2.consecutiveHits, 2)
        XCTAssertEqual(s2.freezeAt, 800,
                       "freeze at height before the feedback streak")

        // Non-feedback clears the streak (one-shot false positive recovery).
        let clear = HTMLBodyLayout.observeFeedback(
            previousHeight: 600, previousViewport: 600,
            height: 620, viewport: 605,
            consecutiveHits: 1, streakBaseHeight: 500)
        XCTAssertEqual(clear.consecutiveHits, 0)
        XCTAssertNil(clear.streakBaseHeight)
        XCTAssertNil(clear.freezeAt)
    }

    func testObserveFeedbackRefusesFreezeBelowViewport() {
        // Early-load false positive: tiny base, viewport already larger.
        let s1 = HTMLBodyLayout.observeFeedback(
            previousHeight: 120, previousViewport: 120,
            height: 170, viewport: 170,
            consecutiveHits: 0, streakBaseHeight: nil)
        XCTAssertEqual(s1.consecutiveHits, 1)
        XCTAssertEqual(s1.streakBaseHeight, 120)
        XCTAssertNil(s1.freezeAt)

        let s2 = HTMLBodyLayout.observeFeedback(
            previousHeight: 170, previousViewport: 170,
            height: 220, viewport: 220,
            consecutiveHits: s1.consecutiveHits,
            streakBaseHeight: s1.streakBaseHeight)
        XCTAssertEqual(s2.consecutiveHits, 2)
        XCTAssertEqual(s2.streakBaseHeight, 120)
        XCTAssertNil(s2.freezeAt,
                     "must not freeze when base (120) is below viewport (220)")
    }

    func testObserveFeedbackPreservesStreakWhenBelowViewportGuardBlocks() {
        // Guard blocks freeze but keeps hits so a later near-viewport sample can freeze.
        let s1 = HTMLBodyLayout.observeFeedback(
            previousHeight: 500, previousViewport: 500,
            height: 550, viewport: 550,
            consecutiveHits: 0, streakBaseHeight: nil)
        XCTAssertEqual(s1.consecutiveHits, 1)
        XCTAssertNil(s1.freezeAt)

        let s2 = HTMLBodyLayout.observeFeedback(
            previousHeight: 550, previousViewport: 550,
            height: 600, viewport: 600,
            consecutiveHits: s1.consecutiveHits,
            streakBaseHeight: s1.streakBaseHeight)
        XCTAssertEqual(s2.consecutiveHits, 2)
        XCTAssertEqual(s2.streakBaseHeight, 500)
        XCTAssertNil(s2.freezeAt, "base 500 << viewport 600 — guard blocks")

        // Streak preserved (hits still >= threshold). A subsequent feedback
        // sample with viewport close enough to base can freeze.
        // Construct via consecutiveHits already at threshold and small dVH:
        // base 500 cannot pass with large viewport; use a tall-base streak.
        let tall1 = HTMLBodyLayout.observeFeedback(
            previousHeight: 900, previousViewport: 900,
            height: 950, viewport: 950,
            consecutiveHits: 0, streakBaseHeight: nil)
        XCTAssertEqual(tall1.consecutiveHits, 1)
        XCTAssertNil(tall1.freezeAt)

        // Second hit still far: base 900, viewport 1000 — still blocked, hits kept.
        let tall2 = HTMLBodyLayout.observeFeedback(
            previousHeight: 950, previousViewport: 950,
            height: 1000, viewport: 1000,
            consecutiveHits: tall1.consecutiveHits,
            streakBaseHeight: tall1.streakBaseHeight)
        XCTAssertEqual(tall2.consecutiveHits, 2)
        XCTAssertNil(tall2.freezeAt)
        XCTAssertEqual(tall2.streakBaseHeight, 900)

        // Third hit: small growth, viewport 903 from a reset-like prior close to base.
        // Same streak base 900; viewport 903 → 900+4 >= 903 → freeze.
        let tall3 = HTMLBodyLayout.observeFeedback(
            previousHeight: 900, previousViewport: 900,
            height: 905, viewport: 903,
            consecutiveHits: tall2.consecutiveHits,
            streakBaseHeight: tall2.streakBaseHeight)
        XCTAssertEqual(tall3.consecutiveHits, 3)
        XCTAssertEqual(tall3.freezeAt, 900,
                       "preserved streak freezes once base is within tolerance of viewport")
    }

    func testObserveFeedbackStillFreezesWhenBaseAtLeastViewport() {
        // base + tolerance >= viewport → freeze allowed (hits already at threshold-1).
        let s = HTMLBodyLayout.observeFeedback(
            previousHeight: 700, previousViewport: 700,
            height: 705, viewport: 704,
            consecutiveHits: 1, streakBaseHeight: 700)
        // base 700 + tol 4 >= viewport 704
        XCTAssertEqual(s.freezeAt, 700)
        XCTAssertEqual(s.consecutiveHits, 2)
        XCTAssertEqual(s.streakBaseHeight, 700)
    }

    func testObserveFreezeRecoveryAdoptsWhenViewportStableAndTaller() {
        // Need N stable viewport samples and measured > frozen + tol.
        let n = HTMLBodyLayout.freezeRecoveryStableViewportSamples
        XCTAssertEqual(n, 2)

        // Sample 1: viewport stable count → 1, not enough yet.
        let r1 = HTMLBodyLayout.observeFreezeRecovery(
            frozenHeight: 120,
            measuredHeight: 480,
            previousViewport: 400,
            viewport: 400,
            stableViewportSamples: 0,
            adoptionsUsed: 0)
        XCTAssertNil(r1.adoptHeight)
        XCTAssertEqual(r1.stableViewportSamples, 1)
        XCTAssertEqual(r1.adoptionsUsed, 0)

        // Sample 2: stable reaches N, adopt measured (clamped).
        let r2 = HTMLBodyLayout.observeFreezeRecovery(
            frozenHeight: 120,
            measuredHeight: 480,
            previousViewport: 400,
            viewport: 400,
            stableViewportSamples: r1.stableViewportSamples,
            adoptionsUsed: r1.adoptionsUsed)
        XCTAssertEqual(r2.adoptHeight, 480)
        XCTAssertEqual(r2.stableViewportSamples, 0)
        XCTAssertEqual(r2.adoptionsUsed, 1)
    }

    func testObserveFreezeRecoveryHoldsWhenViewportStillGrowing() {
        let r = HTMLBodyLayout.observeFreezeRecovery(
            frozenHeight: 120,
            measuredHeight: 480,
            previousViewport: 400,
            viewport: 450,
            stableViewportSamples: 1,
            adoptionsUsed: 0)
        XCTAssertNil(r.adoptHeight, "growing viewport is real feedback — do not adopt")
        XCTAssertEqual(r.stableViewportSamples, 0)
    }

    func testObserveFreezeRecoveryRequiresHeightMargin() {
        // Measured only slightly above frozen — hold.
        let r1 = HTMLBodyLayout.observeFreezeRecovery(
            frozenHeight: 200,
            measuredHeight: 200 + HTMLBodyLayout.freezeRecoveryHeightTolerance,
            previousViewport: 300,
            viewport: 300,
            stableViewportSamples: 1,
            adoptionsUsed: 0)
        // stable becomes 2, but measured is not strictly greater than frozen+tol
        XCTAssertNil(r1.adoptHeight)
        XCTAssertEqual(r1.stableViewportSamples, 2)

        let r2 = HTMLBodyLayout.observeFreezeRecovery(
            frozenHeight: 200,
            measuredHeight: 200 + HTMLBodyLayout.freezeRecoveryHeightTolerance + 1,
            previousViewport: 300,
            viewport: 300,
            stableViewportSamples: 1,
            adoptionsUsed: 0)
        XCTAssertEqual(r2.adoptHeight, 200 + HTMLBodyLayout.freezeRecoveryHeightTolerance + 1)
    }

    func testObserveFreezeRecoveryRespectsAdoptionBudget() {
        let max = HTMLBodyLayout.freezeRecoveryMaxAdoptions
        let r = HTMLBodyLayout.observeFreezeRecovery(
            frozenHeight: 100,
            measuredHeight: 500,
            previousViewport: 400,
            viewport: 400,
            stableViewportSamples: 10,
            adoptionsUsed: max)
        XCTAssertNil(r.adoptHeight, "budget exhausted — freeze permanent")
        XCTAssertEqual(r.adoptionsUsed, max)
        XCTAssertEqual(r.stableViewportSamples, 0)
    }

    func testObserveFreezeRecoveryClampsAdoptedHeight() {
        let r = HTMLBodyLayout.observeFreezeRecovery(
            frozenHeight: 100,
            measuredHeight: CGFloat(HTMLBodyLayout.maxContentHeight + 5000),
            previousViewport: 400,
            viewport: 400,
            stableViewportSamples: 1,
            adoptionsUsed: 0)
        XCTAssertEqual(r.adoptHeight, CGFloat(HTMLBodyLayout.maxContentHeight))
    }

    func testFeedbackHitsToFreezeMatchesJS() {
        let js = HTMLBodyLayout.installLayoutAndMeasureJS
        XCTAssertTrue(js.contains("var HITS_TO_FREEZE=\(HTMLBodyLayout.feedbackHitsToFreeze)"))
        XCTAssertTrue(js.contains("var MIN_DELTA=\(Int(HTMLBodyLayout.feedbackMinDelta.rounded()))"))
        XCTAssertTrue(js.contains("var DELTA_TOL=\(Int(HTMLBodyLayout.feedbackDeltaTolerance.rounded()))"))
        XCTAssertTrue(js.contains("var RECOVERY_STABLE_VH=\(HTMLBodyLayout.freezeRecoveryStableViewportSamples)"))
        XCTAssertTrue(js.contains("var RECOVERY_TOL=\(Int(HTMLBodyLayout.freezeRecoveryHeightTolerance.rounded()))"))
        XCTAssertTrue(js.contains("var RECOVERY_MAX_ADOPTIONS=\(HTMLBodyLayout.freezeRecoveryMaxAdoptions)"))
    }

    // MARK: - CSS / JS contracts

    func testImageCSSMentionsLayoutClasses() {
        let css = HTMLBodyLayout.imageCSS
        XCTAssertTrue(css.contains(HTMLBodyLayout.layoutImageClass))
        XCTAssertTrue(css.contains(HTMLBodyLayout.failedImageClass))
    }

    func testAntiFeedbackCSSNeutralizesFullBleedHeights() {
        let css = HTMLBodyLayout.antiFeedbackCSS
        XCTAssertTrue(css.contains("height=\"100%\""))
        XCTAssertTrue(css.contains(HTMLBodyLayout.heightNeutralizedClass))
        XCTAssertTrue(css.contains("height: auto !important"))
        // Bare height="100" is 100px spacers in transactional mail — must NOT
        // be collapsed (Fable finding: percent-only full-bleed rule).
        XCTAssertFalse(css.contains("[height=\"100\"]"),
                       "bare height=100 is fixed px, not full-bleed")
        // Percent form is present (attribute selector with quotes).
        XCTAssertTrue(css.contains("[height=\"100%\"]") || css.contains("height=\"100%\""))
        // Inline percentage heights (declaration-anchored, same as vh).
        XCTAssertTrue(css.contains("height:100%") || css.contains("[style*=\"height:100%\" i]"))
        XCTAssertTrue(css.contains("height: 100%") || css.contains("[style*=\"height: 100%\" i]"))
        XCTAssertTrue(css.contains("min-height:100%") || css.contains("[style*=\"min-height:100%\" i]"))
        XCTAssertTrue(css.contains("min-height: 100%") || css.contains("[style*=\"min-height: 100%\" i]"))
    }

    func testAntiFeedbackCSSUsesDeclarationAnchoredViewportUnits() {
        let css = HTMLBodyLayout.antiFeedbackCSS
        // Anchored to min-height/height declarations — not bare "100vh".
        XCTAssertTrue(css.contains("min-height:100vh") || css.contains("min-height: 100vh"))
        XCTAssertTrue(css.contains("height:100vh") || css.contains("height: 100vh"))
        XCTAssertTrue(css.contains("100dvh"))
        // Bare substring selector removed (would match 1100vh).
        XCTAssertFalse(css.contains("[style*=\"100vh\""),
                       "bare 100vh substring over-matches (e.g. 1100vh)")
    }

    func testInjectedDarkModeCSSIncludesLayoutImageRules() {
        let css = HTMLBodyDarkMode.injectedCSS(fontScale: 1)
        XCTAssertTrue(css.contains("img { max-width: 100%; height: auto; }"))
        XCTAssertTrue(css.contains(HTMLBodyLayout.layoutImageClass))
        XCTAssertTrue(css.contains(HTMLBodyLayout.failedImageClass))
        // Anti-feedback rules ship with every message document.
        XCTAssertTrue(css.contains("100vh") || css.contains("min-height:100vh"))
        XCTAssertTrue(css.contains(HTMLBodyLayout.heightNeutralizedClass))
    }

    func testLayoutJSPreservesAndClearsDimensions() {
        let js = HTMLBodyLayout.installLayoutAndMeasureJS
        // Cap constants match Swift.
        XCTAssertTrue(js.contains("var MAX_W=\(HTMLBodyLayout.maxPreservedWidth)"))
        XCTAssertTrue(js.contains("var MAX_H=\(HTMLBodyLayout.maxPreservedHeight)"))
        XCTAssertTrue(js.contains("var MAX_CONTENT_H=\(HTMLBodyLayout.maxContentHeight)"))
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
        // Infinite-scroll breakers.
        XCTAssertTrue(js.contains("neutralizeViewportHeights"))
        XCTAssertTrue(js.contains("__mmFrozenH"))
        XCTAssertTrue(js.contains("__mmLastNeutralVH"))
        XCTAssertTrue(js.contains("__mmFeedbackHits"))
        XCTAssertTrue(js.contains("isFeedbackGrowth"))
        XCTAssertTrue(js.contains("observeFreezeRecovery"))
        XCTAssertTrue(js.contains("__mmFreezeStableVH"))
        XCTAssertTrue(js.contains("__mmFreezeAdoptions"))
        XCTAssertTrue(js.contains("postHeight"))
        XCTAssertTrue(js.contains(HTMLBodyLayout.heightNeutralizedClass))
        // Unfreeze on real image geometry; false-freeze recovery without images.
        XCTAssertTrue(js.contains("naturalWidth > 0"))
        XCTAssertTrue(js.contains("setProperty('min-height'"))
        // Percentage-authored height neutralization (not fixed px heroes).
        XCTAssertTrue(js.contains("setProperty('height', 'auto'"))
        XCTAssertTrue(js.contains("authoredPct"))
        XCTAssertTrue(js.contains("charAt") && js.contains("'%'"))
        // Below-viewport freeze guard.
        XCTAssertTrue(js.contains("base + DELTA_TOL >= vh"))
    }

    func testTeardownJSDisconnectsObserverAndClearsFeedbackState() {
        let js = HTMLBodyLayout.teardownJS
        XCTAssertTrue(js.contains("__mmRO"))
        XCTAssertTrue(js.contains("disconnect"))
        // Recycled views must not keep freeze / feedback streak from a prior document.
        XCTAssertTrue(js.contains("__mmFrozenH"))
        XCTAssertTrue(js.contains("__mmFeedbackHits"))
        XCTAssertTrue(js.contains("__mmFeedbackBase"))
        XCTAssertTrue(js.contains("__mmLastNeutralVH"))
        XCTAssertTrue(js.contains("__mmFreezeStableVH"))
        XCTAssertTrue(js.contains("__mmFreezeAdoptions"))
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
