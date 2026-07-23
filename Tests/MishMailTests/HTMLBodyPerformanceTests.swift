import XCTest

final class HTMLBodyPerformanceTests: XCTestCase {
    func testLoadKeyUsesStableContentIdentityAndRenderOptions() {
        let base = HTMLBodyLoadKey(
            contentID: "account:message:authored",
            allowRemoteImages: false,
            fontScale: 1)
        XCTAssertEqual(base, HTMLBodyLoadKey(
            contentID: "account:message:authored",
            allowRemoteImages: false,
            fontScale: 1))
        XCTAssertNotEqual(base, HTMLBodyLoadKey(
            contentID: "account:message:full",
            allowRemoteImages: false,
            fontScale: 1))
        XCTAssertNotEqual(base, HTMLBodyLoadKey(
            contentID: "account:message:authored",
            allowRemoteImages: true,
            fontScale: 1))
        XCTAssertNotEqual(base, HTMLBodyLoadKey(
            contentID: "account:message:authored",
            allowRemoteImages: false,
            fontScale: 1.2))
    }

    func testLargeBodyRequiresExplicitApproval() {
        let limit = HTMLBodyRenderPolicy.maximumAutomaticBytes
        XCTAssertFalse(HTMLBodyRenderPolicy.requiresExplicitLoad(
            byteCount: limit,
            userApproved: false))
        XCTAssertTrue(HTMLBodyRenderPolicy.requiresExplicitLoad(
            byteCount: limit + 1,
            userApproved: false))
        XCTAssertFalse(HTMLBodyRenderPolicy.requiresExplicitLoad(
            byteCount: limit + 1,
            userApproved: true))
        XCTAssertFalse(HTMLBodyRenderPolicy.quoteExpansionApprovesFullBody(
            byteCount: limit))
        XCTAssertTrue(HTMLBodyRenderPolicy.quoteExpansionApprovesFullBody(
            byteCount: limit + 1))
    }

    func testNavigationGateRejectsOldCallbackBeforeNewNavigationStarts() {
        let oldNavigation = NSObject()
        var gate = HTMLNavigationIdentityGate()
        gate.didStart(oldNavigation)
        XCTAssertTrue(gate.accepts(oldNavigation))

        gate.reset()
        XCTAssertFalse(gate.accepts(oldNavigation))
    }

    func testNavigationGateMatchesIdentityAndSupportsNilTokenFallback() {
        let expected = NSObject()
        let stale = NSObject()
        var gate = HTMLNavigationIdentityGate()

        gate.didStart(expected)
        XCTAssertTrue(gate.accepts(expected))
        XCTAssertFalse(gate.accepts(stale))
        XCTAssertFalse(gate.accepts(nil))

        gate.didStart(nil)
        XCTAssertTrue(gate.accepts(nil))
        XCTAssertTrue(gate.accepts(stale))
    }

    func testHeightTrackerPublishesChangesButNotDuplicateReports() {
        var tracker = HTMLHeightStability()

        XCTAssertEqual(
            tracker.observe(120),
            .init(shouldPublish: true, isStable: false))
        XCTAssertEqual(
            tracker.observe(120.5),
            .init(shouldPublish: false, isStable: true))
        XCTAssertEqual(
            tracker.observe(123),
            .init(shouldPublish: true, isStable: false))
        XCTAssertEqual(
            tracker.observe(123),
            .init(shouldPublish: false, isStable: true))
    }

    func testHeightTrackerResetForNewDocument() {
        var tracker = HTMLHeightStability()
        _ = tracker.observe(400)
        _ = tracker.observe(400)
        tracker.reset()

        XCTAssertNil(tracker.lastHeight)
        XCTAssertEqual(tracker.stableSamples, 0)
        XCTAssertTrue(tracker.observe(400).shouldPublish)
    }

    func testLoadKeyPoolKeyIncludesContentRemoteAndScale() {
        let key = HTMLBodyLoadKey(
            contentID: "m1:full", allowRemoteImages: false, fontScale: 1.25)
        XCTAssertEqual(key.poolKey, "m1:full|r=0|f=1.250")
        XCTAssertNotEqual(
            key.poolKey,
            HTMLBodyLoadKey(
                contentID: "m1:full", allowRemoteImages: true, fontScale: 1.25)
                .poolKey)
    }

    func testHeightCacheEvictsLeastRecentlyUsed() {
        var cache = HTMLBodyHeightCache(capacity: 2)
        cache.store(100, for: "a")
        cache.store(200, for: "b")
        XCTAssertEqual(cache.height(for: "a"), 100) // a is now most recent

        cache.store(300, for: "c")

        XCTAssertNil(cache.height(for: "b"))
        XCTAssertEqual(cache.height(for: "a"), 100)
        XCTAssertEqual(cache.height(for: "c"), 300)
    }

    func testHeightCacheIgnoresNonPositive() {
        var cache = HTMLBodyHeightCache(capacity: 4)
        cache.store(0, for: "a")
        cache.store(-10, for: "b")
        XCTAssertNil(cache.height(for: "a"))
        XCTAssertNil(cache.height(for: "b"))
    }

    func testPoolLedgerPrefersFreeThenStealsOldestPrerender() {
        var ledger = HTMLWebViewPoolLedger(capacity: 3)
        ledger.parkFree()
        _ = ledger.parkPrerender(key: "prev")
        _ = ledger.parkPrerender(key: "next")
        XCTAssertEqual(ledger.parkedCount, 3)

        XCTAssertEqual(ledger.acquireForDequeue(), .free)
        XCTAssertEqual(ledger.acquireForDequeue(), .stolenPrerender("prev"))
        XCTAssertEqual(ledger.acquireForDequeue(), .stolenPrerender("next"))
        XCTAssertEqual(ledger.acquireForDequeue(), .createNew)
    }

    func testPoolLedgerParkPrerenderEvictsOldestWhenFull() {
        var ledger = HTMLWebViewPoolLedger(capacity: 2)
        _ = ledger.parkPrerender(key: "a")
        _ = ledger.parkPrerender(key: "b")
        let dropped = ledger.parkPrerender(key: "c")
        XCTAssertEqual(dropped, "a")
        XCTAssertEqual(ledger.prerenderOrder, ["b", "c"])
        XCTAssertTrue(ledger.claimPrerender(key: "c"))
        XCTAssertFalse(ledger.claimPrerender(key: "a"))
    }

    func testPoolLedgerParkPrerenderDropsFreeBeforePainted() {
        var ledger = HTMLWebViewPoolLedger(capacity: 2)
        ledger.parkFree()
        ledger.parkFree()
        XCTAssertEqual(ledger.freeCount, 2)
        let dropped = ledger.parkPrerender(key: "ready")
        XCTAssertNil(dropped)
        XCTAssertEqual(ledger.freeCount, 1)
        XCTAssertEqual(ledger.prerenderOrder, ["ready"])
    }

    func testPrerenderSelectionPrefersAuthoredHead() {
        let html = """
        <div>New reply body</div>
        <div class="gmail_quote">On Mon, someone wrote:<br>history</div>
        """
        let candidate = HTMLBodyPrerenderSelection.candidate(
            messageId: "m1", bodyHTML: html)
        XCTAssertEqual(candidate?.contentID, "m1:authored")
        XCTAssertEqual(candidate?.html.contains("New reply body"), true)
        XCTAssertEqual(candidate?.html.contains("gmail_quote"), false)
    }

    func testPrerenderSelectionSkipsOversizedBodies() {
        let huge = String(repeating: "x", count: HTMLBodyRenderPolicy.maximumAutomaticBytes + 1)
        let wrapped = "<div>\(huge)</div>"
        XCTAssertNil(HTMLBodyPrerenderSelection.candidate(
            messageId: "m1", bodyHTML: wrapped))
    }

    func testPrerenderSelectionUsesFullWhenNoQuote() {
        let html = "<p>Hello only</p>"
        let candidate = HTMLBodyPrerenderSelection.candidate(
            messageId: "m2", bodyHTML: html)
        XCTAssertEqual(candidate?.contentID, "m2:full")
        XCTAssertEqual(candidate?.html, html)
    }
}
