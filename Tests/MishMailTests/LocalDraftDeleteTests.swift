import XCTest
import GRDB

/// Local-first discard: message row gone immediately; thread re-derived or deleted.
final class LocalDraftDeleteTests: XCTestCase {
    private let account = "a@x.com"

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: account, displayName: "A", historyId: nil,
                        lastSyncAt: nil, senderName: "").insert(db)
        }
        return q
    }

    private func message(id: String, thread: String, labels: String,
                         date: Date = Date()) -> Message {
        Message(
            id: "\(account):\(id)", accountId: account, gmailId: id,
            threadId: "\(account):\(thread)", fromHeader: "Ron <a@x.com>",
            toHeader: "b@x.com", ccHeader: "", bccHeader: "", subject: "Re: hi",
            date: date, snippet: "snip", bodyText: "body \(id)", bodyHTML: nil,
            messageIdHeader: "<\(id)@mail>", referencesHeader: "",
            labelIds: labels, isUnread: false, hasAttachment: false)
    }

    func testDeletingLastDraftRemovesThread() throws {
        let q = try makeDB()
        let draft = message(id: "d1", thread: "t1", labels: "DRAFT")
        try q.write { db in
            _ = try SyncEngine.upsertPending(db, items: [
                .init(message: draft, attachments: [])
            ])
            try SyncEngine.deriveThreads(db, for: [draft.threadId], accountId: account)
            XCTAssertNotNil(try MailThread.fetchOne(db, key: draft.threadId))
            let outcome = try SyncEngine.deleteLocalMessage(
                db, messageId: draft.id, threadId: draft.threadId, accountId: account)
            XCTAssertEqual(outcome, .threadDeleted)
            XCTAssertNil(try Message.fetchOne(db, key: draft.id))
            XCTAssertNil(try MailThread.fetchOne(db, key: draft.threadId))
        }
    }

    func testDeletingDraftAmongSentRederivesAndClearsInDrafts() throws {
        let q = try makeDB()
        let sent = message(id: "s1", thread: "t1", labels: "INBOX SENT",
                           date: Date(timeIntervalSince1970: 100))
        let draft = message(id: "d1", thread: "t1", labels: "DRAFT",
                            date: Date(timeIntervalSince1970: 200))
        try q.write { db in
            _ = try SyncEngine.upsertPending(db, items: [
                .init(message: sent, attachments: []),
                .init(message: draft, attachments: []),
            ])
            try SyncEngine.deriveThreads(db, for: [draft.threadId], accountId: account)
            let before = try XCTUnwrap(try MailThread.fetchOne(db, key: draft.threadId))
            XCTAssertTrue(before.inDrafts)

            let outcome = try SyncEngine.deleteLocalMessage(
                db, messageId: draft.id, threadId: draft.threadId, accountId: account)
            XCTAssertEqual(outcome, .threadRederived)
            XCTAssertNil(try Message.fetchOne(db, key: draft.id))
            XCTAssertNotNil(try Message.fetchOne(db, key: sent.id))
            let after = try XCTUnwrap(try MailThread.fetchOne(db, key: draft.threadId))
            XCTAssertFalse(after.inDrafts, "discard must clear inDrafts when no live draft remains")
            XCTAssertTrue(after.inInbox)
            XCTAssertEqual(after.messageCount, 1)
        }
    }

    func testMissingMessageIsNoOp() throws {
        let q = try makeDB()
        try q.write { db in
            let outcome = try SyncEngine.deleteLocalMessage(
                db, messageId: "\(account):gone", threadId: "\(account):t1",
                accountId: account)
            XCTAssertEqual(outcome, .missing)
        }
    }

    // MARK: - Autosave swap (replaceLocalDraft)

    func testAutosaveSwapKeepsDraftOnlyThreadInDrafts() throws {
        let q = try makeDB()
        let old = message(id: "d1", thread: "t1", labels: "DRAFT",
                          date: Date(timeIntervalSince1970: 100))
        let new = message(id: "d2", thread: "t1", labels: "DRAFT",
                          date: Date(timeIntervalSince1970: 200))
        try q.write { db in
            _ = try SyncEngine.upsertPending(db, items: [.init(message: old, attachments: [])])
            try SyncEngine.deriveThreads(db, for: [old.threadId], accountId: account)

            let touched = try SyncEngine.replaceLocalDraft(
                db, replacing: old, with: .init(message: new, attachments: []))
            XCTAssertEqual(touched, [old.threadId])
            XCTAssertNil(try Message.fetchOne(db, key: old.id))
            XCTAssertNotNil(try Message.fetchOne(db, key: new.id))
            let thread = try XCTUnwrap(try MailThread.fetchOne(db, key: old.threadId),
                                       "draft-only thread must survive an autosave")
            XCTAssertTrue(thread.inDrafts)
            XCTAssertEqual(thread.messageCount, 1)
            let body = try MessageBody.fetchOne(db, key: new.id)
            XCTAssertEqual(body?.bodyText, "body d2", "the swap stores the full body")
        }
    }

    func testAutosaveSwapKeepsReplyThreadInDrafts() throws {
        let q = try makeDB()
        let sent = message(id: "s1", thread: "t1", labels: "INBOX SENT",
                           date: Date(timeIntervalSince1970: 50))
        let old = message(id: "d1", thread: "t1", labels: "DRAFT",
                          date: Date(timeIntervalSince1970: 100))
        let new = message(id: "d2", thread: "t1", labels: "DRAFT",
                          date: Date(timeIntervalSince1970: 200))
        try q.write { db in
            _ = try SyncEngine.upsertPending(db, items: [
                .init(message: sent, attachments: []),
                .init(message: old, attachments: []),
            ])
            try SyncEngine.deriveThreads(db, for: [old.threadId], accountId: account)
            try SyncEngine.replaceLocalDraft(
                db, replacing: old, with: .init(message: new, attachments: []))
            let thread = try XCTUnwrap(try MailThread.fetchOne(db, key: old.threadId))
            XCTAssertTrue(thread.inDrafts, "reply thread must stay in Drafts mid-edit")
            XCTAssertTrue(thread.inInbox)
            XCTAssertEqual(thread.messageCount, 2)
        }
    }

    func testAutosaveSwapAcrossThreadsDeletesEmptiedOldThread() throws {
        let q = try makeDB()
        let old = message(id: "d1", thread: "t1", labels: "DRAFT")
        let new = message(id: "d2", thread: "t2", labels: "DRAFT")
        try q.write { db in
            _ = try SyncEngine.upsertPending(db, items: [.init(message: old, attachments: [])])
            try SyncEngine.deriveThreads(db, for: [old.threadId], accountId: account)
            let touched = try SyncEngine.replaceLocalDraft(
                db, replacing: old, with: .init(message: new, attachments: []))
            XCTAssertEqual(touched, [old.threadId, new.threadId])
            XCTAssertNil(try MailThread.fetchOne(db, key: old.threadId))
            XCTAssertTrue(try XCTUnwrap(try MailThread.fetchOne(db, key: new.threadId)).inDrafts)
        }
    }

    func testFirstSaveWithoutOldDraftInsertsThread() throws {
        let q = try makeDB()
        let new = message(id: "d1", thread: "t1", labels: "DRAFT")
        try q.write { db in
            let touched = try SyncEngine.replaceLocalDraft(
                db, replacing: nil, with: .init(message: new, attachments: []))
            XCTAssertEqual(touched, [new.threadId])
            XCTAssertTrue(try XCTUnwrap(try MailThread.fetchOne(db, key: new.threadId)).inDrafts)
        }
    }
}
