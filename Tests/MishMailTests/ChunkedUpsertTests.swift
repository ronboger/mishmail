import XCTest
import GRDB

/// SyncEngine.upsertPending — batched message writes used by fetchAll and
/// the incremental full-fetch path to amortize SQLCipher transaction cost.
final class ChunkedUpsertTests: XCTestCase {

    private let account = "ron@x.com"

    private func migrate() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
        }
        return q
    }

    private func pending(gmailId: String, threadGmailId: String = "t1",
                         withAttachment: Bool = false) -> SyncEngine.PendingUpsert {
        let messageId = "\(account):\(gmailId)"
        let message = Message(
            id: messageId, accountId: account, gmailId: gmailId,
            threadId: "\(account):\(threadGmailId)",
            fromHeader: "Jane <jane@y.com>", toHeader: account,
            ccHeader: "", bccHeader: "", subject: "Subj \(gmailId)",
            date: Date(timeIntervalSince1970: 1_751_500_000),
            snippet: "snip", bodyText: "body \(gmailId)", bodyHTML: nil,
            messageIdHeader: "<\(gmailId)@mail>", referencesHeader: "",
            labelIds: "INBOX", isUnread: true, hasAttachment: withAttachment)
        var attachments: [AttachmentRow] = []
        if withAttachment {
            attachments.append(AttachmentRow(
                id: nil, messageId: messageId, gmailAttachmentId: "att-\(gmailId)",
                filename: "f-\(gmailId).pdf", mimeType: "application/pdf", size: 12))
        }
        return SyncEngine.PendingUpsert(message: message, attachments: attachments)
    }

    func testEmptyBatchIsNoOp() throws {
        let q = try migrate()
        let keys = try q.write { db in
            try SyncEngine.upsertPending(db, items: [])
        }
        XCTAssertTrue(keys.isEmpty)
        XCTAssertEqual(try q.read { try Message.fetchCount($0) }, 0)
    }

    func testBatchWritesAllRowsAndAttachments() throws {
        let q = try migrate()
        let items = (0..<5).map { i in
            pending(gmailId: "m\(i)", threadGmailId: i < 3 ? "t1" : "t2",
                    withAttachment: i == 0)
        }
        let keys = try q.write { db in
            try SyncEngine.upsertPending(db, items: items)
        }
        XCTAssertEqual(keys, Set(["\(account):t1", "\(account):t2"]))
        XCTAssertEqual(try q.read { try Message.fetchCount($0) }, 5)
        XCTAssertEqual(try q.read { try AttachmentRow.fetchCount($0) }, 1)

        let m0 = try q.read { try Message.fetchOne($0, key: "\(account):m0") }
        // v24: body lives in message_body; on-row columns stay empty.
        XCTAssertEqual(m0?.bodyText, "")
        XCTAssertTrue(m0?.hasAttachment == true)
        let body = try q.read { try MessageBody.fetchOne($0, key: "\(account):m0") }
        XCTAssertEqual(body?.bodyText, "body m0")
    }

    func testBatchUpsertReplacesAttachments() throws {
        let q = try migrate()
        let first = pending(gmailId: "m1", withAttachment: true)
        _ = try q.write { db in try SyncEngine.upsertPending(db, items: [first]) }

        // Same message, new attachment id — old attachment rows must go.
        var second = pending(gmailId: "m1", withAttachment: true)
        second = SyncEngine.PendingUpsert(
            message: second.message,
            attachments: [AttachmentRow(
                id: nil, messageId: "\(account):m1", gmailAttachmentId: "att-new",
                filename: "new.pdf", mimeType: "application/pdf", size: 99)])
        _ = try q.write { db in try SyncEngine.upsertPending(db, items: [second]) }

        let atts = try q.read {
            try AttachmentRow.filter(Column("messageId") == "\(account):m1").fetchAll($0)
        }
        XCTAssertEqual(atts.count, 1)
        XCTAssertEqual(atts.first?.gmailAttachmentId, "att-new")
        XCTAssertEqual(atts.first?.filename, "new.pdf")
    }

    /// N messages across multiple chunk-sized flushes still leave N rows and
    /// derivation over the returned keys still works.
    func testChunkedFlushesThenDerivation() throws {
        let q = try migrate()
        let n = SyncEngine.writeChunkSize + 5
        var allKeys = Set<String>()
        var buffer: [SyncEngine.PendingUpsert] = []
        for i in 0..<n {
            buffer.append(pending(gmailId: "m\(i)", threadGmailId: "t\(i % 3)"))
            if buffer.count >= SyncEngine.writeChunkSize {
                let keys = try q.write { db in
                    try SyncEngine.upsertPending(db, items: buffer)
                }
                allKeys.formUnion(keys)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            let keys = try q.write { db in
                try SyncEngine.upsertPending(db, items: buffer)
            }
            allKeys.formUnion(keys)
        }

        XCTAssertEqual(try q.read { try Message.fetchCount($0) }, n)
        XCTAssertEqual(allKeys.count, 3)

        try q.write { db in
            try SyncEngine.deriveThreads(db, for: allKeys, accountId: account)
        }
        let threads = try q.read { try MailThread.fetchCount($0) }
        XCTAssertEqual(threads, 3)
    }

    /// A deliberate failure inside a write transaction rolls back the whole
    /// chunk — no partial rows, schema still usable for a later successful write.
    func testFailedChunkRollsBackWithoutCorruption() throws {
        let q = try migrate()
        _ = try q.write { db in
            try SyncEngine.upsertPending(db, items: [pending(gmailId: "seed")])
        }
        XCTAssertEqual(try q.read { try Message.fetchCount($0) }, 1)

        struct ChunkBoom: Error {}
        do {
            try q.write { db in
                // Two valid rows in the same transaction…
                _ = try SyncEngine.upsertPending(db, items: [
                    pending(gmailId: "ok1"),
                    pending(gmailId: "ok2"),
                ])
                // …then abort before commit (same fate as any mid-chunk error).
                throw ChunkBoom()
            }
            XCTFail("expected write to throw")
        } catch is ChunkBoom {
            // expected
        }

        // Chunk rolled back: only the pre-chunk seed remains.
        XCTAssertEqual(try q.read { try Message.fetchCount($0) }, 1)
        XCTAssertNotNil(try q.read { try Message.fetchOne($0, key: "\(account):seed") })

        // Schema still healthy: a subsequent batch succeeds.
        _ = try q.write { db in
            try SyncEngine.upsertPending(db, items: [
                pending(gmailId: "after1"),
                pending(gmailId: "after2"),
            ])
        }
        XCTAssertEqual(try q.read { try Message.fetchCount($0) }, 3)
    }
}
