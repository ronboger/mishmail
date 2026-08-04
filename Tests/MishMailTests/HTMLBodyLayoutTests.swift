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
        // Hit 1: record streak base height + viewport, no freeze yet — even when
        // base is already within tolerance of the streak-start viewport.
        let s1 = HTMLBodyLayout.observeFeedback(
            previousHeight: 800, previousViewport: 800,
            height: 805, viewport: 804,
            consecutiveHits: 0, streakBaseHeight: nil, streakBaseViewport: nil)
        XCTAssertEqual(s1.consecutiveHits, 1)
        XCTAssertEqual(s1.streakBaseHeight, 800)
        XCTAssertEqual(s1.streakBaseViewport, 800)
        XCTAssertNil(s1.freezeAt)

        // Hit 2: freeze at pre-streak height when base + tol >= streak-start viewport.
        // Guard is anchored to streak-start viewport (not live), so consecutive
        // feedback hits still freeze even if the live viewport has grown.
        let s2 = HTMLBodyLayout.observeFeedback(
            previousHeight: 800, previousViewport: 800,
            height: 805, viewport: 804,
            consecutiveHits: 1, streakBaseHeight: 800, streakBaseViewport: 800)
        XCTAssertEqual(s2.consecutiveHits, 2)
        XCTAssertEqual(s2.streakBaseViewport, 800)
        XCTAssertEqual(s2.freezeAt, 800,
                       "freeze at height before the feedback streak")

        // Non-feedback clears the streak (one-shot false positive recovery).
        let clear = HTMLBodyLayout.observeFeedback(
            previousHeight: 600, previousViewport: 600,
            height: 620, viewport: 605,
            consecutiveHits: 1, streakBaseHeight: 500, streakBaseViewport: 500)
        XCTAssertEqual(clear.consecutiveHits, 0)
        XCTAssertNil(clear.streakBaseHeight)
        XCTAssertNil(clear.streakBaseViewport)
        XCTAssertNil(clear.freezeAt)
    }

    /// Regression: measure→frame→viewport runaway with content = viewport + 20.
    /// Before streak-start viewport anchoring, sample 2 compared base against the
    /// *live* viewport (100+4 >= 120) and refused forever as vh kept growing.
    /// Must freeze at hit 2 at the pre-streak base.
    func testObserveFeedbackFreezesRunawayDespiteGrowingViewport() {
        // sample 1: prev(100, 80) → (120, 100): feedback, hits 1, base 100 / baseVH 80
        let s1 = HTMLBodyLayout.observeFeedback(
            previousHeight: 100, previousViewport: 80,
            height: 120, viewport: 100,
            consecutiveHits: 0, streakBaseHeight: nil, streakBaseViewport: nil)
        XCTAssertEqual(s1.consecutiveHits, 1)
        XCTAssertEqual(s1.streakBaseHeight, 100)
        XCTAssertEqual(s1.streakBaseViewport, 80)
        XCTAssertNil(s1.freezeAt)

        // sample 2: prev(120, 100) → (140, 120): live vh 120 has drifted past base,
        // but guard uses streak-start vh 80 → 100+4 >= 80 → freeze at 100.
        let s2 = HTMLBodyLayout.observeFeedback(
            previousHeight: 120, previousViewport: 100,
            height: 140, viewport: 120,
            consecutiveHits: s1.consecutiveHits,
            streakBaseHeight: s1.streakBaseHeight,
            streakBaseViewport: s1.streakBaseViewport)
        XCTAssertEqual(s2.consecutiveHits, 2)
        XCTAssertEqual(s2.streakBaseHeight, 100)
        XCTAssertEqual(s2.streakBaseViewport, 80)
        XCTAssertEqual(s2.freezeAt, 100,
                       "runaway must freeze at pre-streak base; live vh must not defeat guard")

        // sample 3 (would also freeze if not already frozen): live vh still grows.
        let s3 = HTMLBodyLayout.observeFeedback(
            previousHeight: 140, previousViewport: 120,
            height: 160, viewport: 140,
            consecutiveHits: s2.consecutiveHits,
            streakBaseHeight: s2.streakBaseHeight,
            streakBaseViewport: s2.streakBaseViewport)
        XCTAssertEqual(s3.consecutiveHits, 3)
        XCTAssertEqual(s3.freezeAt, 100)
    }

    func testObserveFeedbackRefusesFreezeBelowViewport() {
        // Early-load false positive: tiny content base while the viewport is
        // already larger *at streak start* (not merely after live growth).
        // base 120 << streakBaseViewport 220 → guard must refuse.
        let s1 = HTMLBodyLayout.observeFeedback(
            previousHeight: 120, previousViewport: 220,
            height: 170, viewport: 270,
            consecutiveHits: 0, streakBaseHeight: nil, streakBaseViewport: nil)
        XCTAssertEqual(s1.consecutiveHits, 1)
        XCTAssertEqual(s1.streakBaseHeight, 120)
        XCTAssertEqual(s1.streakBaseViewport, 220)
        XCTAssertNil(s1.freezeAt)

        let s2 = HTMLBodyLayout.observeFeedback(
            previousHeight: 170, previousViewport: 270,
            height: 220, viewport: 320,
            consecutiveHits: s1.consecutiveHits,
            streakBaseHeight: s1.streakBaseHeight,
            streakBaseViewport: s1.streakBaseViewport)
        XCTAssertEqual(s2.consecutiveHits, 2)
        XCTAssertEqual(s2.streakBaseHeight, 120)
        XCTAssertEqual(s2.streakBaseViewport, 220)
        XCTAssertNil(s2.freezeAt,
                     "must not freeze when base (120) is below streak-start viewport (220)")
    }

    func testObserveFeedbackPreservesStreakWhenBelowViewportGuardBlocks() {
        // Guard blocks freeze but keeps hits/base/baseVH for the life of the streak.
        // base 500 << streak-start viewport 600.
        let s1 = HTMLBodyLayout.observeFeedback(
            previousHeight: 500, previousViewport: 600,
            height: 550, viewport: 650,
            consecutiveHits: 0, streakBaseHeight: nil, streakBaseViewport: nil)
        XCTAssertEqual(s1.consecutiveHits, 1)
        XCTAssertEqual(s1.streakBaseHeight, 500)
        XCTAssertEqual(s1.streakBaseViewport, 600)
        XCTAssertNil(s1.freezeAt)

        let s2 = HTMLBodyLayout.observeFeedback(
            previousHeight: 550, previousViewport: 650,
            height: 600, viewport: 700,
            consecutiveHits: s1.consecutiveHits,
            streakBaseHeight: s1.streakBaseHeight,
            streakBaseViewport: s1.streakBaseViewport)
        XCTAssertEqual(s2.consecutiveHits, 2)
        XCTAssertEqual(s2.streakBaseHeight, 500)
        XCTAssertEqual(s2.streakBaseViewport, 600)
        XCTAssertNil(s2.freezeAt, "base 500 << streak-start viewport 600 — guard blocks")

        // Streak preserved across further feedback samples; freeze decision is
        // fixed for this streak (base and baseVH do not change), so still refused.
        let s3 = HTMLBodyLayout.observeFeedback(
            previousHeight: 600, previousViewport: 700,
            height: 650, viewport: 750,
            consecutiveHits: s2.consecutiveHits,
            streakBaseHeight: s2.streakBaseHeight,
            streakBaseViewport: s2.streakBaseViewport)
        XCTAssertEqual(s3.consecutiveHits, 3)
        XCTAssertEqual(s3.streakBaseHeight, 500)
        XCTAssertEqual(s3.streakBaseViewport, 600)
        XCTAssertNil(s3.freezeAt, "guard still blocks; streak not cleared")

        // A *new* streak whose base is within tolerance of its own streak-start
        // viewport freezes normally (guard is per-streak, not permanent).
        let tall1 = HTMLBodyLayout.observeFeedback(
            previousHeight: 900, previousViewport: 900,
            height: 950, viewport: 950,
            consecutiveHits: 0, streakBaseHeight: nil, streakBaseViewport: nil)
        XCTAssertEqual(tall1.consecutiveHits, 1)
        XCTAssertEqual(tall1.streakBaseHeight, 900)
        XCTAssertEqual(tall1.streakBaseViewport, 900)
        XCTAssertNil(tall1.freezeAt)

        let tall2 = HTMLBodyLayout.observeFeedback(
            previousHeight: 950, previousViewport: 950,
            height: 1000, viewport: 1000,
            consecutiveHits: tall1.consecutiveHits,
            streakBaseHeight: tall1.streakBaseHeight,
            streakBaseViewport: tall1.streakBaseViewport)
        XCTAssertEqual(tall2.consecutiveHits, 2)
        XCTAssertEqual(tall2.streakBaseHeight, 900)
        XCTAssertEqual(tall2.freezeAt, 900,
                       "new streak freezes when base is within tolerance of streak-start viewport")
    }

    func testObserveFeedbackStillFreezesWhenBaseAtLeastViewport() {
        // base + tolerance >= streak-start viewport → freeze allowed
        // (hits already at threshold-1).
        let s = HTMLBodyLayout.observeFeedback(
            previousHeight: 700, previousViewport: 700,
            height: 705, viewport: 704,
            consecutiveHits: 1, streakBaseHeight: 700, streakBaseViewport: 700)
        // base 700 + tol 4 >= streak-start viewport 700
        XCTAssertEqual(s.freezeAt, 700)
        XCTAssertEqual(s.consecutiveHits, 2)
        XCTAssertEqual(s.streakBaseHeight, 700)
        XCTAssertEqual(s.streakBaseViewport, 700)
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
        // Below-viewport freeze guard anchored to streak-start viewport.
        XCTAssertTrue(js.contains("__mmFeedbackBaseVH"))
        XCTAssertTrue(js.contains("base + DELTA_TOL >= baseVH")
                      || js.contains("base + DELTA_TOL >= window.__mmFeedbackBaseVH"))
    }

    func testTeardownJSDisconnectsObserverAndClearsFeedbackState() {
        let js = HTMLBodyLayout.teardownJS
        XCTAssertTrue(js.contains("__mmRO"))
        XCTAssertTrue(js.contains("disconnect"))
        // Recycled views must not keep freeze / feedback streak from a prior document.
        XCTAssertTrue(js.contains("__mmFrozenH"))
        XCTAssertTrue(js.contains("__mmFeedbackHits"))
        XCTAssertTrue(js.contains("__mmFeedbackBase"))
        XCTAssertTrue(js.contains("__mmFeedbackBaseVH"))
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
