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
        XCTAssertTrue(RemoteImagePolicy.allows(
            policy: .vip, senderEmail: "friend@x.com", vipEmails: vips,
            messageOptIn: false, threadOptIn: false))
        XCTAssertTrue(RemoteImagePolicy.allows(
            policy: .vip, senderEmail: "Friend@X.com", vipEmails: vips,
            messageOptIn: false, threadOptIn: false))
        XCTAssertFalse(RemoteImagePolicy.allows(
            policy: .vip, senderEmail: "stranger@x.com", vipEmails: vips,
            messageOptIn: false, threadOptIn: false))
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
