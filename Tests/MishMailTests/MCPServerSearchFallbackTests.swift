import XCTest
import GRDB

/// Policy + pure helpers for MCP `search_threads` falling back to Gmail
/// "Search all of Gmail" when the local cache has no hits (old mail).
final class MCPServerSearchFallbackTests: XCTestCase {

    func testShouldPullOnlyWhenLocalEmptyOnFirstPage() {
        XCTAssertTrue(MCPTools.shouldPullServerSearch(localCount: 0, offset: 0))
        XCTAssertFalse(MCPTools.shouldPullServerSearch(localCount: 1, offset: 0))
        XCTAssertFalse(MCPTools.shouldPullServerSearch(localCount: 0, offset: 25))
        XCTAssertFalse(MCPTools.shouldPullServerSearch(localCount: 3, offset: 10))
    }

    func testSearchThreadsDescriptionMentionsServerFallback() {
        let tool = MCPTools.catalog.first { $0.name == "search_threads" }
        XCTAssertNotNil(tool)
        let desc = tool?.description ?? ""
        XCTAssertTrue(desc.localizedCaseInsensitiveContains("Gmail")
                      || desc.localizedCaseInsensitiveContains("server"),
                      "description should advertise server fallback: \(desc)")
        XCTAssertTrue(desc.localizedCaseInsensitiveContains("sync window")
                      || desc.localizedCaseInsensitiveContains("Search all"),
                      "description should mention cache/window or Search all: \(desc)")
    }

    func testOrderedUniqueGmailThreadIdsPreservesRankAndDedupes() {
        let refs: [(id: String, threadId: String)] = [
            ("m1", "tA"),
            ("m2", "tB"),
            ("m3", "tA"), // same thread, later message
            ("m4", "tC"),
            ("m5", "tD"),
        ]
        XCTAssertEqual(
            SyncEngine.orderedUniqueGmailThreadIds(from: refs, limit: 10),
            ["tA", "tB", "tC", "tD"])
        XCTAssertEqual(
            SyncEngine.orderedUniqueGmailThreadIds(from: refs, limit: 2),
            ["tA", "tB"])
        XCTAssertEqual(
            SyncEngine.orderedUniqueGmailThreadIds(from: refs, limit: 0),
            [])
        XCTAssertEqual(
            SyncEngine.orderedUniqueGmailThreadIds(from: [], limit: 5),
            [])
    }

    func testLocalThreadIdsPrefixAccount() {
        XCTAssertEqual(
            SyncEngine.localThreadIds(accountId: "ron@x.com", gmailThreadIds: ["t1", "t2"]),
            ["ron@x.com:t1", "ron@x.com:t2"])
        XCTAssertEqual(
            SyncEngine.localThreadIds(accountId: "a@b", gmailThreadIds: []),
            [])
    }

    /// Mirrors MCPBridge.threadsByIds ordering: caller order wins over SQL order.
    func testThreadsByIdsPreservesCallerOrder() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO account (id, displayName, senderName)
                VALUES ('ron@x.com', 'P', '')
                """)
            for (tid, subject, day) in [
                ("ron@x.com:t1", "First", "2026-01-01 12:00:00"),
                ("ron@x.com:t2", "Second", "2026-06-01 12:00:00"),
                ("ron@x.com:t3", "Third", "2026-03-01 12:00:00"),
            ] as [(String, String, String)] {
                try db.execute(sql: """
                    INSERT INTO thread (id, accountId, gmailThreadId, subject, snippet,
                        fromDisplay, lastDate, isUnread, isStarred, inInbox, inTrash,
                        labelIds, participants, messageCount, hasAttachment)
                    VALUES (?, 'ron@x.com', ?, ?, 'sn', 'Jane', ?, 0, 0, 1, 0,
                        'INBOX', 'Jane', 1, 0)
                    """, arguments: [tid, String(tid.split(separator: ":").last!), subject, day])
            }
        }

        let order = ["ron@x.com:t2", "ron@x.com:t1", "ron@x.com:t3", "ron@x.com:missing"]
        let found = try q.read { db -> [String] in
            let rows = try MailThread.filter(order.contains(Column("id"))).fetchAll(db)
            let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            return order.compactMap { byId[$0]?.subject }
        }
        XCTAssertEqual(found, ["Second", "First", "Third"])
    }
}
