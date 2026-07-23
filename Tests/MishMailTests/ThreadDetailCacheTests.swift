import XCTest
import GRDB

final class ThreadDetailCacheTests: XCTestCase {
    func testLRUEvictsLeastRecentlyUsed() {
        var cache = ThreadDetailLRU<Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        XCTAssertEqual(cache.value(for: "a"), 1) // a is now most recent

        cache.insert(3, for: "c")

        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.value(for: "a"), 1)
        XCTAssertEqual(cache.value(for: "c"), 3)
    }

    func testLRUReplacementDoesNotDuplicateOrder() {
        var cache = ThreadDetailLRU<Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "a")
        cache.insert(3, for: "b")

        XCTAssertEqual(cache.order, ["a", "b"])
        XCTAssertEqual(cache.value(for: "a"), 2)
    }

    func testDraftSuppressionDropsMessagesAndAttachmentsTogether() {
        let sent = fixtureMessage(id: "sent", labels: "INBOX")
        let draft = fixtureMessage(id: "draft", labels: "DRAFT")
        let payload = ThreadDetailPayload(
            messages: [sent, draft],
            attachmentsByMessageId: [
                "sent": [fixtureAttachment(messageId: "sent")],
                "draft": [fixtureAttachment(messageId: "draft")],
            ],
            bodyPrepByMessageId: [
                "sent": .empty,
                "draft": .empty,
            ])

        let visible = payload.suppressingDrafts(["draft"])

        XCTAssertEqual(visible.messages.map(\.id), ["sent"])
        XCTAssertEqual(Set(visible.attachmentsByMessageId.keys), ["sent"])
        XCTAssertEqual(Set(visible.bodyPrepByMessageId.keys), ["sent"])
    }

    func testMessageHTMLPrepDetectsQuotedTrailAndAssemblesDocuments() throws {
        let html = """
        <div>New reply</div>
        <div class="gmail_quote">On Mon, Alice wrote:<br>Earlier</div>
        """
        let prep = MessageHTMLPrepBuilder.prep(
            bodyText: "New reply\n\nOn Mon, Alice wrote:\n> Earlier",
            bodyHTML: html,
            fontScale: 1.0)

        XCTAssertTrue(prep.hasQuotedTrail)
        XCTAssertNotNil(prep.htmlHead)
        XCTAssertFalse(prep.htmlHead?.contains("gmail_quote") ?? true)
        XCTAssertEqual(prep.htmlBytes, html.utf8.count)
        let docs = try XCTUnwrap(prep.documents)
        XCTAssertEqual(docs.fontScale, 1.0)
        // Authored + full for both image policies.
        XCTAssertNotNil(docs.authoredBlocked)
        XCTAssertNotNil(docs.authoredAllowed)
        XCTAssertNotNil(docs.fullBlocked)
        XCTAssertNotNil(docs.fullAllowed)
        // Assembled documents inject CSP + CSS.
        XCTAssertTrue(docs.fullBlocked?.contains("Content-Security-Policy") ?? false)
        XCTAssertTrue(docs.authoredBlocked?.contains("New reply") ?? false)
        XCTAssertFalse(docs.authoredBlocked?.contains("gmail_quote") ?? true)
    }

    func testMessageHTMLPrepSkipsAssemblyAboveAutomaticByteBudget() {
        // Oversized body: trail scan is bounded; no auto-render documents.
        let big = String(repeating: "x", count: HTMLBodyRenderPolicy.maximumAutomaticBytes + 1)
        let html = "<div>\(big)</div>"
        let prep = MessageHTMLPrepBuilder.prep(
            bodyText: "", bodyHTML: html, fontScale: 1.0)
        XCTAssertEqual(prep.htmlBytes, html.utf8.count)
        // Full assembly is skipped — nothing under the 2 MB auto budget.
        XCTAssertNil(prep.documents?.fullBlocked)
        XCTAssertNil(prep.documents?.fullAllowed)
    }

    func testMessageHTMLPrepReassembleKeepsTrail() {
        let html = """
        <div>Hi</div>
        <div class="gmail_quote">quoted</div>
        """
        let prep = MessageHTMLPrepBuilder.prep(
            bodyText: "Hi", bodyHTML: html, fontScale: 1.0)
        let rebuilt = MessageHTMLPrepBuilder.reassembleDocuments(
            prep, fullHTML: html, fontScale: 1.2)
        XCTAssertEqual(rebuilt.htmlHead, prep.htmlHead)
        XCTAssertEqual(rebuilt.hasQuotedTrail, prep.hasQuotedTrail)
        XCTAssertEqual(rebuilt.documents?.fontScale, 1.2)
        XCTAssertNotNil(rebuilt.documents?.fullBlocked)
    }

    func testContentVersionMismatchReloadsPrefetchedThread() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("thread-detail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("mail.sqlite").path
        let pool = try DatabasePool(path: path)
        try AppDatabase.migrator.migrate(pool)
        try await pool.write { db in
            try Account(
                id: "me@example.com", displayName: "Me", historyId: nil,
                lastSyncAt: nil, senderName: "Me").insert(db)
            _ = try SyncEngine.upsertPending(
                db, items: [.init(message: self.fixtureMessage(
                    id: "m1", labels: "INBOX"), attachments: [])])
        }
        let repository = ThreadDetailRepository(db: pool)

        let prefetched = await repository.payload(
            threadId: "thread", suppressingDrafts: [],
            contentVersion: 1)
        XCTAssertFalse(prefetched.cacheHit)
        XCTAssertEqual(prefetched.payload.messages.map(\.id), ["m1"])

        try await pool.write { db in
            _ = try SyncEngine.upsertPending(
                db, items: [.init(message: self.fixtureMessage(
                    id: "m2", labels: "INBOX"), attachments: [])])
        }
        let sameVersion = await repository.payload(
            threadId: "thread", suppressingDrafts: [],
            contentVersion: 1)
        XCTAssertTrue(sameVersion.cacheHit)
        XCTAssertEqual(sameVersion.payload.messages.map(\.id), ["m1"])

        let refreshed = await repository.payload(
            threadId: "thread", suppressingDrafts: [],
            contentVersion: 2)
        XCTAssertFalse(refreshed.cacheHit)
        XCTAssertEqual(
            Set(refreshed.payload.messages.map(\.id)),
            ["m1", "m2"])
    }

    private func fixtureMessage(id: String, labels: String,
                                bodyText: String = "",
                                bodyHTML: String? = nil) -> Message {
        Message(
            id: id, accountId: "me@example.com", gmailId: id, threadId: "thread",
            fromHeader: "A <a@example.com>", toHeader: "me@example.com",
            ccHeader: "", subject: "Subject", date: Date(), snippet: "",
            bodyText: bodyText, bodyHTML: bodyHTML, messageIdHeader: "<\(id)>",
            referencesHeader: "", labelIds: labels, isUnread: false,
            hasAttachment: false)
    }

    private func fixtureAttachment(messageId: String) -> AttachmentRow {
        AttachmentRow(
            id: nil, messageId: messageId, gmailAttachmentId: "att",
            filename: "file.txt", mimeType: "text/plain", size: 1)
    }
}
