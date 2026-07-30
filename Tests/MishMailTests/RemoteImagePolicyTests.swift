import XCTest

final class RemoteImagePolicyTests: XCTestCase {

    func testAskBlocksUnlessOptIn() {
        let vips: Set<String> = ["friend@x.com"]
        XCTAssertFalse(RemoteImagePolicy.allows(
            policy: .ask, senderEmail: "friend@x.com", vipEmails: vips,
            messageOptIn: false, threadOptIn: false))
        XCTAssertTrue(RemoteImagePolicy.allows(
            policy: .ask, senderEmail: "stranger@x.com", vipEmails: vips,
            messageOptIn: true, threadOptIn: false))
        XCTAssertTrue(RemoteImagePolicy.allows(
            policy: .ask, senderEmail: "stranger@x.com", vipEmails: vips,
            messageOptIn: false, threadOptIn: true))
    }

    func testVIPAllowsOnlyListedSenders() {
        let vips: Set<String> = ["friend@x.com"]
        // .vip fails closed without an auth verdict: only an aligned DMARC
        // pass (senderAuthenticated == true) lets a VIP auto-load.
        XCTAssertFalse(RemoteImagePolicy.allows(
            policy: .vip, senderEmail: "friend@x.com", vipEmails: vips,
            messageOptIn: false, threadOptIn: false,
            senderAuthenticated: nil))
        XCTAssertTrue(RemoteImagePolicy.allows(
            policy: .vip, senderEmail: "friend@x.com", vipEmails: vips,
            messageOptIn: false, threadOptIn: false,
            senderAuthenticated: true))
        XCTAssertTrue(RemoteImagePolicy.allows(
            policy: .vip, senderEmail: "Friend@X.com", vipEmails: vips,
            messageOptIn: false, threadOptIn: false,
            senderAuthenticated: true))
        XCTAssertFalse(RemoteImagePolicy.allows(
            policy: .vip, senderEmail: "stranger@x.com", vipEmails: vips,
            messageOptIn: false, threadOptIn: false,
            senderAuthenticated: true))
    }

    /// The From: header is spoofable, so VIP auto-load fails closed on an
    /// explicit Gmail Authentication-Results failure — a forged VIP address
    /// must not fire tracking pixels. An explicit click always wins.
    func testVIPBlocksAuthFailure() {
        let vips: Set<String> = ["friend@x.com"]
        XCTAssertFalse(RemoteImagePolicy.allows(
            policy: .vip, senderEmail: "friend@x.com", vipEmails: vips,
            messageOptIn: false, threadOptIn: false,
            senderAuthenticated: false))
        // An explicit click still wins over an auth failure.
        XCTAssertTrue(RemoteImagePolicy.allows(
            policy: .vip, senderEmail: "friend@x.com", vipEmails: vips,
            messageOptIn: true, threadOptIn: false,
            senderAuthenticated: false))
        XCTAssertTrue(RemoteImagePolicy.allows(
            policy: .vip, senderEmail: "friend@x.com", vipEmails: vips,
            messageOptIn: false, threadOptIn: true,
            senderAuthenticated: false))
    }

    func testAlwaysAllowsEveryone() {
        XCTAssertTrue(RemoteImagePolicy.allows(
            policy: .always, senderEmail: "anyone@x.com", vipEmails: [],
            messageOptIn: false, threadOptIn: false))
    }

    func testMigrateFromLegacyBoolTrue() {
        let suite = "RemoteImagePolicyTests.legacy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: RemoteImagePolicy.legacyBoolKey)
        RemoteImagePolicy.migrateIfNeeded(defaults)
        XCTAssertEqual(defaults.string(forKey: RemoteImagePolicy.defaultsKey),
                       RemoteImagePolicy.always.rawValue)
        XCTAssertNil(defaults.object(forKey: RemoteImagePolicy.legacyBoolKey))

        // Second migrate is a no-op even if legacy key reappears.
        defaults.set(false, forKey: RemoteImagePolicy.legacyBoolKey)
        RemoteImagePolicy.migrateIfNeeded(defaults)
        XCTAssertEqual(defaults.string(forKey: RemoteImagePolicy.defaultsKey),
                       RemoteImagePolicy.always.rawValue)
    }

    func testMigrateFromLegacyBoolFalse() {
        let suite = "RemoteImagePolicyTests.legacyFalse.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(false, forKey: RemoteImagePolicy.legacyBoolKey)
        RemoteImagePolicy.migrateIfNeeded(defaults)
        XCTAssertEqual(defaults.string(forKey: RemoteImagePolicy.defaultsKey),
                       RemoteImagePolicy.ask.rawValue)
        XCTAssertNil(defaults.object(forKey: RemoteImagePolicy.legacyBoolKey))
    }

    func testMigrateNoopWhenNoLegacyKey() {
        let suite = "RemoteImagePolicyTests.ask.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Fresh install: don't pin .ask into defaults so a future default change applies.
        RemoteImagePolicy.migrateIfNeeded(defaults)
        XCTAssertNil(defaults.object(forKey: RemoteImagePolicy.defaultsKey))
        XCTAssertEqual(RemoteImagePolicy.stored(defaults), .ask)
    }
}
