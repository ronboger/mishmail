import XCTest
import GRDB

/// Pins SidebarCounts COUNT predicates to *indexed* plans (not full-table
/// SCAN). SQLite may pick a v18 composite over a v21 partial when both apply
/// (e.g. starred → `thread_on_isStarred_inTrash_lastDate`); that still
/// satisfies the goal. v21/v22 partial *existence* is asserted in
/// DatabaseMigrationTests; reminder/snoozed partials are the ones the
/// planner actually needs (no competing composite).
final class SidebarCountsIndexTests: XCTestCase {

    private func explainDetail(_ db: Database, sql: String,
                               arguments: StatementArguments = StatementArguments()) throws -> String {
        let rows = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)",
                                    arguments: arguments)
        return rows.map { "\($0["detail"] as String? ?? "")" }.joined(separator: " | ")
    }

    /// COUNT must not devolve to an unindexed full scan of `thread`.
    private func assertIndexedCount(_ db: Database, sql: String,
                                    arguments: StatementArguments = StatementArguments(),
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let detail = try explainDetail(db, sql: sql, arguments: arguments)
        // "SCAN thread" without USING INDEX = bad. SEARCH … USING INDEX = good.
        // Covering SEARCH on a partial or composite is fine.
        let unindexedScan = detail.range(
            of: #"\bSCAN\s+thread\b(?!.*USING)"#,
            options: .regularExpression) != nil
            && !detail.localizedCaseInsensitiveContains("USING INDEX")
            && !detail.localizedCaseInsensitiveContains("USING COVERING INDEX")
        XCTAssertFalse(
            unindexedScan || detail == "SCAN thread",
            "expected indexed COUNT plan, got: \(detail)",
            file: file, line: line)
        XCTAssertTrue(
            detail.localizedCaseInsensitiveContains("USING INDEX")
                || detail.localizedCaseInsensitiveContains("USING COVERING INDEX")
                || detail.localizedCaseInsensitiveContains("SEARCH"),
            "expected SEARCH/INDEX plan, got: \(detail)",
            file: file, line: line)
    }

    func testPrimaryCountPredicatesAreIndexed() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.read { db in
            try self.assertIndexedCount(db, sql: """
                SELECT COUNT(*) FROM thread
                WHERE isUnread = 1 AND inTrash = 0 AND inSpam = 0 AND inInbox = 1
                  AND inPromotions = 0 AND inSocial = 0
                """)
            try self.assertIndexedCount(db, sql: """
                SELECT COUNT(*) FROM thread
                WHERE accountId = ? AND isUnread = 1 AND inTrash = 0 AND inSpam = 0
                  AND inInbox = 1 AND inPromotions = 0 AND inSocial = 0
                """, arguments: ["a@x.com"])
            try self.assertIndexedCount(db, sql: """
                SELECT COUNT(*) FROM thread
                WHERE isStarred = 1 AND inTrash = 0
                """)
            try self.assertIndexedCount(db, sql: """
                SELECT COUNT(*) FROM thread
                WHERE inDrafts = 1 AND inTrash = 0
                """)
        }
    }

    /// v22 partials have no v18 competitor — pin the exact index name so a
    /// predicate drift that drops the partial is caught.
    func testReminderAndSnoozedCountsUseV22Indexes() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.read { db in
            let rem = try self.explainDetail(db, sql: """
                SELECT COUNT(*) FROM thread
                WHERE reminderAt IS NOT NULL
                """)
            XCTAssertTrue(rem.localizedCaseInsensitiveContains("thread_has_reminder"),
                          "got: \(rem)")
            let snooze = try self.explainDetail(db, sql: """
                SELECT COUNT(*) FROM thread
                WHERE snoozeUntil IS NOT NULL AND snoozeUntil > ? AND inTrash = 0
                """, arguments: [Date()])
            XCTAssertTrue(snooze.localizedCaseInsensitiveContains("thread_snoozed_active"),
                          "got: \(snooze)")
        }
    }
}
