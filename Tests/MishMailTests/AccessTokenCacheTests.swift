import XCTest

final class AccessTokenCacheTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testEmptyCacheHasNoToken() {
        XCTAssertNil(AccessTokenCache().token(now: now))
    }

    func testStoredTokenIsReturnedUntilTheExpiryMargin() {
        var cache = AccessTokenCache()
        XCTAssertTrue(cache.store("tok", expiresIn: 3600, now: now,
                                  generation: cache.generation))
        XCTAssertEqual(cache.token(now: now), "tok")
        XCTAssertEqual(cache.token(now: now.addingTimeInterval(3600 - 61)), "tok")
        // Inside the last minute a request could outlive the token.
        XCTAssertNil(cache.token(now: now.addingTimeInterval(3600 - 60)))
        XCTAssertNil(cache.token(now: now.addingTimeInterval(4000)))
    }

    func testInvalidateDropsTheTokenAndAdvancesTheGeneration() {
        var cache = AccessTokenCache()
        let before = cache.generation
        cache.store("tok", expiresIn: 3600, now: now, generation: before)
        cache.invalidate()
        XCTAssertNil(cache.token(now: now))
        XCTAssertNotEqual(cache.generation, before)
    }

    /// A refresh that started before the token was forgotten used the old
    /// sign-in. Its result must not repopulate the cache.
    func testStoreFromAnOlderGenerationIsIgnored() {
        var cache = AccessTokenCache()
        let inFlight = cache.generation
        cache.invalidate()
        XCTAssertFalse(cache.store("stale", expiresIn: 3600, now: now,
                                   generation: inFlight))
        XCTAssertNil(cache.token(now: now))

        XCTAssertTrue(cache.store("fresh", expiresIn: 3600, now: now,
                                  generation: cache.generation))
        XCTAssertEqual(cache.token(now: now), "fresh")
        // The stale result can also arrive after the fresh one.
        XCTAssertFalse(cache.store("stale", expiresIn: 3600, now: now,
                                   generation: inFlight))
        XCTAssertEqual(cache.token(now: now), "fresh")
    }

    /// A 401 drops the token but belongs to the same sign-in: the refresh it
    /// triggers, or one already running, must still be accepted.
    func testExpireDropsTheTokenAndKeepsTheGeneration() {
        var cache = AccessTokenCache()
        let generation = cache.generation
        cache.store("tok", expiresIn: 3600, now: now, generation: generation)
        cache.expire()
        XCTAssertNil(cache.token(now: now))
        XCTAssertEqual(cache.generation, generation)
        XCTAssertTrue(cache.store("next", expiresIn: 3600, now: now,
                                  generation: generation))
        XCTAssertEqual(cache.token(now: now), "next")
    }
}
