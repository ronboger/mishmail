import XCTest
import GRDB

final class DemoSeedTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "demoModeEnabled")
        super.tearDown()
    }

    func testDemoCanStartWithoutAccounts() {
        XCTAssertTrue(DemoSeed.canActivate(accountIDs: []))
    }

    func testDemoCanReseedItsOwnFixture() {
        XCTAssertTrue(DemoSeed.canActivate(accountIDs: [DemoSeed.account]))
    }

    func testDemoCannotReplaceARealAccount() {
        XCTAssertFalse(DemoSeed.canActivate(accountIDs: ["person@example.org"]))
        XCTAssertFalse(DemoSeed.canActivate(
            accountIDs: [DemoSeed.account, "person@example.org"]))
    }

    func testVIPsAndGlobalSettingsSurviveDemoEntryAndExit() throws {
        let (pool, path) = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try pool.write { db in
            try VIPSender(email: "vip@example.org", groupName: "Friends").insert(db)
            try BlockedSender(email: "blocked@example.org").insert(db)
        }

        XCTAssertTrue(DemoSeed.activate(pool))
        XCTAssertTrue(DemoSeed.deactivate(pool))

        let state = try pool.read { db in
            (try VIPSender.fetchAll(db), try BlockedSender.fetchAll(db))
        }
        XCTAssertEqual(state.0.map(\.email), ["vip@example.org"])
        XCTAssertEqual(state.0.first?.groupName, "Friends")
        XCTAssertEqual(state.1.map(\.email), ["blocked@example.org"])
    }

    func testLaunchRecoversPreviouslyMixedDatabaseAndStaleDemoFlag() throws {
        let (pool, path) = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(DemoSeed.activate(pool))
        try pool.write { db in
            try Account(id: "person@example.org", displayName: "Real",
                        historyId: nil, lastSyncAt: nil, senderName: "Person").insert(db)
        }

        XCTAssertFalse(DemoSeed.seedIfRequested(pool))

        let ids = try pool.read { try String.fetchAll($0, sql: "SELECT id FROM account") }
        XCTAssertEqual(ids, ["person@example.org"])
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "demoModeEnabled"))
    }

    func testDatabaseReadFailureNeverActivatesDemo() throws {
        let (pool, path) = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try pool.close()

        XCTAssertFalse(DemoSeed.activate(pool))
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "demoModeEnabled"))
    }

    func testFailedReseedKeepsThePreviousFixtureOffline() throws {
        let (pool, path) = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(DemoSeed.activate(pool))
        let originalMessageCount = try pool.read { try Int.fetchOne(
            $0, sql: "SELECT COUNT(*) FROM message") ?? 0 }
        try pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_demo_reseed
                BEFORE INSERT ON account
                WHEN NEW.id = '\(DemoSeed.account)'
                BEGIN
                    SELECT RAISE(FAIL, 'simulated transient write failure');
                END
                """)
        }

        XCTAssertTrue(DemoSeed.seedIfRequested(pool))

        let state = try pool.read { db in
            (try String.fetchAll(db, sql: "SELECT id FROM account"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") ?? 0)
        }
        XCTAssertEqual(state.0, [DemoSeed.account])
        XCTAssertEqual(state.1, originalMessageCount)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "demoModeEnabled"))
    }

    private func makeDatabase() throws -> (DatabasePool, String) {
        let path = NSTemporaryDirectory() + "mishmail-demo-\(UUID().uuidString).sqlite"
        let pool = try DatabasePool(path: path)
        try AppDatabase.migrator.migrate(pool)
        return (pool, path)
    }
}
