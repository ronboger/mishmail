import XCTest
import GRDB

final class VIPMembershipTests: XCTestCase {

    func testNormalizeGroupsTrimsDedupes() {
        XCTAssertEqual(
            VIPMembership.normalizeGroups(["  investors ", "board", "investors", "", "  "]),
            ["investors", "board"])
    }

    func testResolveGroupsMergesGroupAndGroups() {
        XCTAssertEqual(
            VIPMembership.resolveGroups(group: "family", groups: ["work", "family"]),
            ["work", "family"])
        XCTAssertEqual(
            VIPMembership.resolveGroups(group: nil, groups: nil),
            [])
        XCTAssertEqual(
            VIPMembership.resolveGroups(group: "  Suggested ", groups: nil),
            ["Suggested"])
    }

    func testUnionPreservesExistingOrder() {
        XCTAssertEqual(
            VIPMembership.union(existing: ["a", "b"], adding: ["b", "c"]),
            ["a", "b", "c"])
    }

    func testIsActiveAnyGroupEnabled() {
        XCTAssertTrue(VIPMembership.isActive(groups: [], groupEnabled: [:]))
        XCTAssertTrue(VIPMembership.isActive(
            groups: ["work", "family"],
            groupEnabled: ["work": false, "family": true]))
        XCTAssertFalse(VIPMembership.isActive(
            groups: ["work", "family"],
            groupEnabled: ["work": false, "family": false]))
        // Missing key defaults to enabled.
        XCTAssertTrue(VIPMembership.isActive(
            groups: ["new"],
            groupEnabled: [:]))
    }

    // MARK: - Migration + membership persistence

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        return q
    }

    func testMigrationV34CreatesJunctionAndBackfills() throws {
        // Simulate a pre-v34 DB: migrate through v33-equivalent by inserting
        // via the full migrator then verifying the junction exists. Fresh DB
        // already has v34; seed a sender with only groupName and check load path.
        let q = try makeDB()
        try q.read { db in
            XCTAssertTrue(try db.tableExists("vipSenderGroup"), "v34 must add vipSenderGroup")
        }

        try q.write { db in
            try VIPSender(email: "old@x.com", groupName: "Friends").insert(db)
            // Mimic pre-v34: no junction row yet. Backfill is migration-only;
            // load path should still fold denormalized groupName.
        }

        let tags = try q.read { try VIPSenderGroup.fetchAll($0) }
        XCTAssertTrue(tags.isEmpty, "insert via VIPSender alone does not auto-tag junction")

        // Full dual-write path used by MailStore.
        try q.write { db in
            try VIPSender(email: "new@x.com", groupName: "investors").save(db)
            try VIPSenderGroup(email: "new@x.com", groupName: "investors").insert(db)
            try VIPSenderGroup(email: "new@x.com", groupName: "board").insert(db)
            // Keep denormalized primary as first.
            try VIPSender(email: "new@x.com", groupName: "investors").save(db)
        }

        let multi = try q.read {
            try VIPSenderGroup
                .filter(Column("email") == "new@x.com")
                .fetchAll($0)
                .map(\.groupName)
                .sorted()
        }
        XCTAssertEqual(multi, ["board", "investors"])
    }

    func testCascadeDeletesMembershipTags() throws {
        let q = try makeDB()
        try q.write { db in
            try VIPSender(email: "gone@x.com", groupName: "work").insert(db)
            try VIPSenderGroup(email: "gone@x.com", groupName: "work").insert(db)
            try VIPSenderGroup(email: "gone@x.com", groupName: "family").insert(db)
            _ = try VIPSender.deleteOne(db, key: "gone@x.com")
        }
        let leftover = try q.read { try VIPSenderGroup.fetchAll($0) }
        XCTAssertTrue(leftover.isEmpty, "vipSenderGroup must cascade on sender delete")
    }

    func testBackfillOnMigratorFromLegacyGroupName() throws {
        // Build a DB stopped before v34, insert legacy VIP, then finish migrations.
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v33")
        try q.write { db in
            try VIPSender(email: "legacy@x.com", groupName: "Founders").insert(db)
            XCTAssertFalse(try db.tableExists("vipSenderGroup"))
        }
        try AppDatabase.migrator.migrate(q) // through v34
        let tags = try q.read {
            try VIPSenderGroup.fetchAll($0)
        }
        XCTAssertEqual(tags.map { "\($0.email):\($0.groupName)" }, ["legacy@x.com:Founders"])
    }
}
