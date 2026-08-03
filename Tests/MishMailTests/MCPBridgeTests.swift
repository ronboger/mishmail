import XCTest
import GRDB

/// DB-level coverage for migration v32 `threadSummary` and summary upsert rules.
/// (Full `MCPBridge` needs MailStore/AppKit and is not in the hostless suite.)
final class MCPBridgeTests: XCTestCase {

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        return q
    }

    private func seedThread(_ db: Database, id: String = "ron@x.com:t1") throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO account (id, displayName, senderName)
            VALUES ('ron@x.com', 'Personal', '')
            """)
        try db.execute(sql: """
            INSERT INTO thread (id, accountId, gmailThreadId, subject, snippet, fromDisplay,
                lastDate, isUnread, isStarred, inInbox, inTrash, labelIds, participants,
                messageCount, hasAttachment)
            VALUES (?, 'ron@x.com', 't1', 'Hello', 'sn', 'Jane',
                '2026-08-01 12:00:00', 0, 0, 1, 0, 'INBOX', 'Jane', 1, 0)
            """, arguments: [id])
    }

    func testMigrationV32CreatesThreadSummary() throws {
        let q = try makeDB()
        try q.read { db in
            XCTAssertTrue(try db.tableExists("threadSummary"))
            let cols = try db.columns(in: "threadSummary").map(\.name)
            for name in ["threadId", "summary", "model", "updatedAt"] {
                XCTAssertTrue(cols.contains(name), "missing column \(name)")
            }
        }
    }

    func testThreadSummaryUpsertAndCascadeDelete() throws {
        let q = try makeDB()
        try q.write { db in
            try seedThread(db)
            try ThreadSummaryRow(
                threadId: "ron@x.com:t1",
                summary: "Short TL;DR",
                model: "test-model",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ).insert(db)
        }

        let first = try q.read { try ThreadSummaryRow.fetchOne($0, key: "ron@x.com:t1") }
        XCTAssertEqual(first?.summary, "Short TL;DR")
        XCTAssertEqual(first?.model, "test-model")

        // Upsert overwrites.
        try q.write { db in
            try ThreadSummaryRow(
                threadId: "ron@x.com:t1",
                summary: "Updated",
                model: "other",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
            ).save(db)
        }
        let second = try q.read { try ThreadSummaryRow.fetchOne($0, key: "ron@x.com:t1") }
        XCTAssertEqual(second?.summary, "Updated")
        XCTAssertEqual(second?.model, "other")

        // Cascade when thread is deleted.
        try q.write { db in
            _ = try MailThread.deleteOne(db, key: "ron@x.com:t1")
        }
        let after = try q.read { try ThreadSummaryRow.fetchOne($0, key: "ron@x.com:t1") }
        XCTAssertNil(after, "threadSummary must cascade on thread delete")
    }

    func testSetThreadSummaryRejectsUnknownThread() throws {
        let q = try makeDB()
        // Mirrors MCPBridge.setThreadSummary: check existence before write.
        let exists = try q.read { db in
            try MailThread.fetchOne(db, key: "missing:thread") != nil
        }
        XCTAssertFalse(exists)

        // Direct insert without parent should fail FK when foreign_keys are on.
        do {
            try q.write { db in
                try ThreadSummaryRow(
                    threadId: "missing:thread",
                    summary: "x",
                    model: "m",
                    updatedAt: Date()
                ).insert(db)
            }
            // If FK is off in this connection, still assert our app-level check.
            // GRDB enables foreign_keys by default on DatabaseQueue.
            XCTFail("expected foreign key failure for unknown thread")
        } catch {
            // FK violation or equivalent — acceptable.
        }
    }

    func testToolCatalogCountMatchesDesign() {
        XCTAssertEqual(MCPTools.catalog.count, 11)
        XCTAssertEqual(MCPTools.clampedLimit(0), 1)
        XCTAssertEqual(MCPTools.clampedLimit(500), 100)
        XCTAssertEqual(MCPTools.clampedLimit(nil), 25)
    }
}
