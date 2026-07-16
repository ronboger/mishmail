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
}
