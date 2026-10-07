import XCTest

/// WindowBackfill — a sync-window listing that stopped at the per-pass cap
/// is not recorded as finished, and the next pass continues it.
final class WindowBackfillTests: XCTestCase {

    // MARK: - Mark complete or continue

    func testListingThatReachedTheLastPageIsComplete() {
        XCTAssertEqual(WindowBackfill.outcome(listingComplete: true), .complete)
    }

    func testListingCutOffAtTheCapContinuesNextPass() {
        XCTAssertEqual(WindowBackfill.outcome(listingComplete: false), .continueNextPass)
    }

    // MARK: - Does this pass list the window

    func testFinishedWindowIsNotListedAgain() {
        XCTAssertFalse(WindowBackfill.needsListing(storedWindow: 90, listedWindow: 90, days: 90))
        XCTAssertFalse(WindowBackfill.needsListing(storedWindow: 0, listedWindow: 0, days: 0))
    }

    func testTruncatedWindowIsListedAgain() {
        // The window setting is recorded, the finished listing is not.
        XCTAssertTrue(WindowBackfill.needsListing(storedWindow: 90, listedWindow: nil, days: 90))
    }

    /// "Everything" is 0, and an unset integer default also reads 0: the
    /// finished marker must be what decides, not the window key.
    func testEverythingWithNoFinishedListingIsListed() {
        XCTAssertTrue(WindowBackfill.needsListing(storedWindow: 0, listedWindow: nil, days: 0))
    }

    func testChangedWindowIsListed() {
        XCTAssertTrue(WindowBackfill.needsListing(storedWindow: 30, listedWindow: 30, days: 90))
        XCTAssertTrue(WindowBackfill.needsListing(storedWindow: 90, listedWindow: 90, days: 30))
        XCTAssertTrue(WindowBackfill.needsListing(storedWindow: 90, listedWindow: 90, days: 0))
        // Back to a window that was finished long ago, with another between.
        XCTAssertTrue(WindowBackfill.needsListing(storedWindow: 90, listedWindow: 30, days: 90))
    }

    func testListedKeyIsPerAccount() {
        XCTAssertEqual(WindowBackfill.listedKey(accountId: "a@x.com"),
                       "backfill.windowListed.a@x.com")
    }

    // MARK: - Cap

    /// The search and starred listings: every listed id counts, and a page
    /// never lists past the cap.
    func testCapThatCountsListedIds() {
        var cap = WindowBackfill.ListingCap(limit: 1_200, countsCachedIds: true)
        XCTAssertEqual(cap.pageSize, 500)
        cap.record(listed: 500, missing: 0)
        cap.record(listed: 500, missing: 0)
        XCTAssertFalse(cap.reached)
        XCTAssertEqual(cap.pageSize, 200)
        cap.record(listed: 200, missing: 0)
        XCTAssertTrue(cap.reached)
    }

    /// The window listing: ids already cached cost nothing, so a pass walks
    /// over everything an earlier pass downloaded and continues after it.
    func testCapThatCountsOnlyDownloadsWalksPastCachedIds() {
        var cap = WindowBackfill.ListingCap(limit: 3_000, countsCachedIds: false)
        for _ in 0..<40 {
            XCTAssertEqual(cap.pageSize, 500)
            cap.record(listed: 500, missing: 0)
        }
        XCTAssertFalse(cap.reached, "20000 cached ids do not use up the cap")
        for _ in 0..<5 { cap.record(listed: 500, missing: 500) }
        XCTAssertFalse(cap.reached)
        XCTAssertEqual(cap.pageSize, 500, "full pages up to the cap")
        cap.record(listed: 500, missing: 500)
        XCTAssertTrue(cap.reached, "one pass downloads at most about `limit`")
    }

    func testCapPageSizeIsAtLeastOne() {
        var cap = WindowBackfill.ListingCap(limit: 0, countsCachedIds: true)
        XCTAssertEqual(cap.pageSize, 1)
        cap.record(listed: 1, missing: 1)
        XCTAssertTrue(cap.reached)
    }
}
