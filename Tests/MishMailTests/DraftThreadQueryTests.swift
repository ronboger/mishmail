import XCTest
import GRDB

final class DraftThreadQueryTests: XCTestCase {
    private let account = "drafts@example.com"
    private let threadId = "drafts@example.com:t"

    private func makeDB(labels: [String], bodySize: Int = 0) throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: self.account, displayName: "A", historyId: nil,
                        lastSyncAt: nil).insert(db)
            for (i, labelIds) in labels.enumerated() {
                let id = "\(self.account):m\(i)"
                try Message(
                    id: id, accountId: self.account, gmailId: "m\(i)",
                    threadId: self.threadId, fromHeader: self.account,
                    toHeader: "friend@example.com", ccHeader: "", subject: "Draft",
                    date: Date(timeIntervalSince1970: Double(i)), snippet: "",
                    bodyText: "", bodyHTML: nil, messageIdHeader: "",
                    referencesHeader: "", labelIds: labelIds,
                    isUnread: false, hasAttachment: false).insert(db)
                try MessageBody(messageId: id, bodyText: String(repeating: "x", count: bodySize),
                                bodyHTML: nil).insert(db)
            }
        }
        return q
    }

    func testDraftAndDiscardedMessageSemantics() throws {
        let cases: [([String], Bool)] = [
            ([], false),
            (["DRAFT"], true),
            (["INBOX DRAFT", "DRAFT Label_1"], true),
            (["SENT", "DRAFT"], false),
            (["INBOX", "DRAFT"], false),
            (["DRAFT TRASH"], false),
            (["DRAFT", "TRASH DRAFT"], false),
            (["NOTDRAFT", "DRAFT"], false),
            (["DRAFT\tLabel_1"], true),
        ]
        for (labels, expected) in cases {
            let q = try makeDB(labels: labels)
            XCTAssertEqual(try q.read {
                try DraftThreadQuery.isDraftOnly(db: $0, threadId: self.threadId,
                                                suppressing: [])
            }, expected, "labels: \(labels)")
        }
    }

    func testSuppressionIsAppliedBeforeDraftClassification() throws {
        let q = try makeDB(labels: ["DRAFT", "DRAFT TRASH", "SENT"])
        try q.read { db in
            XCTAssertTrue(try DraftThreadQuery.isDraftOnly(
                db: db, threadId: self.threadId,
                suppressing: ["\(self.account):m1", "\(self.account):m2"]))
            XCTAssertFalse(try DraftThreadQuery.isDraftOnly(
                db: db, threadId: self.threadId,
                suppressing: ["\(self.account):m0", "\(self.account):m1", "\(self.account):m2"]))
        }
    }

    func testThreadScopeDoesNotIncludeOtherConversation() throws {
        let q = try makeDB(labels: ["DRAFT"])
        try q.write { db in
            var other = try XCTUnwrap(Message.fetchOne(db, key: "\(self.account):m0"))
            other.id = "\(self.account):other"
            other.gmailId = "other"
            other.threadId = "\(self.account):other-thread"
            other.labelIds = "SENT"
            try other.insert(db)
            XCTAssertTrue(try DraftThreadQuery.isDraftOnly(
                db: db, threadId: self.threadId, suppressing: [other.id]))
            XCTAssertFalse(try DraftThreadQuery.isDraftOnly(
                db: db, threadId: "missing", suppressing: []))
        }
    }

    func testLargeBodiesAreNotReadForDraftClassification() throws {
        let q = try makeDB(labels: Array(repeating: "DRAFT", count: 10), bodySize: 1_000_000)
        try q.read { db in
            var statements: [String] = []
            db.trace { if case .statement(let s) = $0 { statements.append(s.sql) } }
            defer { db.trace(nil) }
            XCTAssertTrue(try DraftThreadQuery.isDraftOnly(
                db: db, threadId: self.threadId, suppressing: []))
            XCTAssertEqual(statements.filter { $0.hasPrefix("SELECT") }.count, 1)
            XCTAssertFalse(statements.contains { $0.lowercased().contains("body") })
        }
    }
}
