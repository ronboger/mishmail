import GRDB
import XCTest

final class ChatStoreTests: XCTestCase {
    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        return q
    }

    func testMigrationCreatesChatTables() throws {
        let q = try makeDB()
        try q.read { db in
            XCTAssertTrue(try db.tableExists("chatConversation"))
            XCTAssertTrue(try db.tableExists("chatMessage"))
        }
    }

    func testConversationAndMessageRoundTrip() throws {
        let q = try makeDB()
        let convo = ChatConversationRow(
            id: "c1", title: "Test", providerID: "p1", modelID: "m1",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100))
        let message = ChatMessageRow(
            id: "m1", conversationId: "c1", role: "assistant", text: "hi",
            toolCallsJSON: "[]", toolResultsJSON: "[]",
            promptTokens: 12, completionTokens: 3,
            createdAt: Date(timeIntervalSince1970: 101))
        try q.write { db in
            try convo.save(db)
            try message.save(db)
        }
        try q.read { db in
            let back = try ChatMessageRow.fetchOne(db, key: "m1")
            XCTAssertEqual(back?.promptTokens, 12)
            XCTAssertEqual(back?.conversationId, "c1")
        }
    }

    func testDeletingConversationCascadesMessages() throws {
        let q = try makeDB()
        try q.write { db in
            try ChatConversationRow(id: "c1", title: "t", providerID: "p", modelID: "m",
                                    createdAt: Date(), updatedAt: Date()).save(db)
            try ChatMessageRow(id: "m1", conversationId: "c1", role: "user", text: "x",
                               toolCallsJSON: "[]", toolResultsJSON: "[]",
                               promptTokens: nil, completionTokens: nil,
                               createdAt: Date()).save(db)
            _ = try ChatConversationRow.deleteOne(db, key: "c1")
        }
        try q.read { db in
            XCTAssertEqual(try ChatMessageRow.fetchCount(db), 0)
        }
    }
}
