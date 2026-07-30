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
        // Blocked variants are eager; allowed are on-demand from retained sources.
        XCTAssertNotNil(docs.authoredBlocked)
        XCTAssertNotNil(docs.fullBlocked)
        XCTAssertNotNil(docs.document(authored: true, allowRemoteImages: true))
        XCTAssertNotNil(docs.document(authored: false, allowRemoteImages: true))
        // Assembled documents inject CSP + CSS.
        XCTAssertTrue(docs.fullBlocked?.contains("Content-Security-Policy") ?? false)
        XCTAssertTrue(docs.authoredBlocked?.contains("New reply") ?? false)
        XCTAssertFalse(docs.authoredBlocked?.contains("gmail_quote") ?? true)
        // Allowed CSP differs from blocked (remote img-src).
        let allowed = try XCTUnwrap(docs.document(authored: false, allowRemoteImages: true))
        XCTAssertTrue(allowed.contains("img-src data: cid: https:"))
        XCTAssertFalse(docs.fullBlocked?.contains("img-src data: cid: https:") ?? true)
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
        XCTAssertNil(prep.documents?.document(authored: false, allowRemoteImages: true))
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

    func testMessageHTMLDocumentsAllowedVariantsAreLazy() throws {
        let html = "<p>Body with tracker <img src=\"https://t.example/p.gif\"></p>"
        let prep = MessageHTMLPrepBuilder.prep(
            bodyText: "Body", bodyHTML: html, fontScale: 1.0)
        let docs = try XCTUnwrap(prep.documents)
        // Eager path only retains blocked documents.
        XCTAssertNotNil(docs.fullBlocked)
        XCTAssertTrue(docs.fullBlocked?.contains("img-src data: cid:") ?? false)
        // Allowed is produced on demand and includes https: in img-src.
        let allowed = docs.document(authored: false, allowRemoteImages: true)
        XCTAssertNotNil(allowed)
        XCTAssertTrue(allowed?.contains("img-src data: cid: https:") ?? false)
        // Authored absent when no quote trail.
        XCTAssertNil(docs.authoredBlocked)
        XCTAssertNil(docs.document(authored: true, allowRemoteImages: false))
    }

    /// `document` is read from MessageCard's SwiftUI body, which re-evaluates
    /// on every height change — assembling per access would stall the main
    /// actor on multi-hundred-KB bodies. Memoized results are shared across
    /// struct copies so the assembly happens once.
    func testMessageHTMLDocumentsAllowedVariantIsMemoizedAcrossCopies() throws {
        let html = "<p>Body <img src=\"https://t.example/p.gif\"></p>"
        let prep = MessageHTMLPrepBuilder.prep(
            bodyText: "Body", bodyHTML: html, fontScale: 1.0)
        let docs = try XCTUnwrap(prep.documents)

        let first = try XCTUnwrap(docs.document(authored: false, allowRemoteImages: true))
        let again = try XCTUnwrap(docs.document(authored: false, allowRemoteImages: true))
        XCTAssertEqual(first, again)

        // A copy reuses the memo rather than reassembling.
        let copy = docs
        XCTAssertEqual(copy.document(authored: false, allowRemoteImages: true), first)
        // Equality ignores the memo — copies stay equal after one side is warmed.
        XCTAssertEqual(copy, docs)
    }

    #if DEBUG
    /// String equality can't distinguish a memo hit from a per-access rebuild
    /// (the jank A2 fixed); the miss counter can.
    func testAllowedVariantAssemblesExactlyOnceAcrossRepeatedAccess() throws {
        let html = "<p>Body <img src=\"https://t.example/p.gif\"></p>"
        let prep = MessageHTMLPrepBuilder.prep(
            bodyText: "Body", bodyHTML: html, fontScale: 1.0)
        let docs = try XCTUnwrap(prep.documents)
        XCTAssertEqual(docs.debugAllowedBuildCount, 0)

        let copy = docs
        _ = docs.document(authored: false, allowRemoteImages: true)
        _ = docs.document(authored: false, allowRemoteImages: true)
        _ = copy.document(authored: false, allowRemoteImages: true)
        XCTAssertEqual(docs.debugAllowedBuildCount, 1)

        // A nil variant (no authored head here) memoizes its miss too.
        _ = docs.document(authored: true, allowRemoteImages: true)
        _ = docs.document(authored: true, allowRemoteImages: true)
        XCTAssertEqual(docs.debugAllowedBuildCount, 2)

        // Blocked variants never touch the memo.
        _ = docs.document(authored: false, allowRemoteImages: false)
        XCTAssertEqual(docs.debugAllowedBuildCount, 2)
    }
    #endif

    /// Reassembling for a new font scale must not serve the old scale's
    /// memoized allowed document.
    func testReassembleDropsMemoizedAllowedVariant() throws {
        let html = "<p>Body <img src=\"https://t.example/p.gif\"></p>"
        let prep = MessageHTMLPrepBuilder.prep(
            bodyText: "Body", bodyHTML: html, fontScale: 1.0)
        let warmed = try XCTUnwrap(prep.documents)
        _ = warmed.document(authored: false, allowRemoteImages: true)

        let rebuilt = MessageHTMLPrepBuilder.reassembleDocuments(
            prep, fullHTML: html, fontScale: 1.6)
        let rebuiltDocs = try XCTUnwrap(rebuilt.documents)
        let allowed = try XCTUnwrap(
            rebuiltDocs.document(authored: false, allowRemoteImages: true))
        XCTAssertEqual(rebuiltDocs.fontScale, 1.6)
        XCTAssertNotEqual(
            allowed, warmed.document(authored: false, allowRemoteImages: true))
    }

    func testBuildBodyPrepMatchesMessageHTMLPrepBuilder() {
        let message = fixtureMessage(
            id: "m1", labels: "INBOX",
            bodyText: "Hi",
            bodyHTML: "<div>Hi</div>")
        let empty = fixtureMessage(id: "m2", labels: "INBOX")
        let prep = ThreadDetailRepository.buildBodyPrep(
            messages: [message, empty], fontScale: 1.0)
        XCTAssertEqual(Set(prep.keys), ["m1"])
        XCTAssertNotNil(prep["m1"]?.documents?.fullBlocked)
        XCTAssertNil(prep["m2"])
    }

    func testRevisionMismatchReloadsPrefetchedThread() async throws {
        let pool = try makeMailPool()
        try await pool.write { db in
            _ = try SyncEngine.upsertPending(
                db, items: [.init(message: self.fixtureMessage(
                    id: "m1", labels: "INBOX"), attachments: [])])
        }
        let repository = ThreadDetailRepository(db: pool)
        var revisions = ThreadContentRevisions()

        let prefetched = await repository.payload(
            threadId: "thread", suppressingDrafts: [],
            revision: revisions.revision(of: "thread"))
        XCTAssertFalse(prefetched.cacheHit)
        XCTAssertEqual(prefetched.payload.messages.map(\.id), ["m1"])

        try await pool.write { db in
            _ = try SyncEngine.upsertPending(
                db, items: [.init(message: self.fixtureMessage(
                    id: "m2", labels: "INBOX"), attachments: [])])
        }
        let sameRevision = await repository.payload(
            threadId: "thread", suppressingDrafts: [],
            revision: revisions.revision(of: "thread"))
        XCTAssertTrue(sameRevision.cacheHit)
        XCTAssertEqual(sameRevision.payload.messages.map(\.id), ["m1"])

        revisions.apply(.threads(["thread"]))
        let refreshed = await repository.payload(
            threadId: "thread", suppressingDrafts: [],
            revision: revisions.revision(of: "thread"))
        XCTAssertFalse(refreshed.cacheHit)
        XCTAssertEqual(
            Set(refreshed.payload.messages.map(\.id)),
            ["m1", "m2"])
    }

    /// The regression this scoping exists for: triage mutates *other* rows all
    /// the time, and each one used to evict the warmed neighbor the user was
    /// about to land on.
    func testUnrelatedThreadChangeKeepsAWarmedPayloadCached() async throws {
        let pool = try makeMailPool()
        try await pool.write { db in
            _ = try SyncEngine.upsertPending(
                db, items: [.init(message: self.fixtureMessage(
                    id: "m1", labels: "INBOX"), attachments: [])])
        }
        let repository = ThreadDetailRepository(db: pool)
        var revisions = ThreadContentRevisions()

        let warmed = await repository.payload(
            threadId: "thread", suppressingDrafts: [],
            revision: revisions.revision(of: "thread"))
        XCTAssertFalse(warmed.cacheHit)

        // A neighbouring conversation was trashed, archived, starred, read…
        revisions.apply(.threads(["some-other-thread"]))

        let landed = await repository.payload(
            threadId: "thread", suppressingDrafts: [],
            revision: revisions.revision(of: "thread"))
        XCTAssertTrue(landed.cacheHit)
    }

    func testEverythingChangeEvictsEveryWarmedPayload() async throws {
        let pool = try makeMailPool()
        try await pool.write { db in
            _ = try SyncEngine.upsertPending(
                db, items: [.init(message: self.fixtureMessage(
                    id: "m1", labels: "INBOX"), attachments: [])])
        }
        let repository = ThreadDetailRepository(db: pool)
        var revisions = ThreadContentRevisions()
        _ = await repository.payload(
            threadId: "thread", suppressingDrafts: [],
            revision: revisions.revision(of: "thread"))

        revisions.apply(.everything)

        let landed = await repository.payload(
            threadId: "thread", suppressingDrafts: [],
            revision: revisions.revision(of: "thread"))
        XCTAssertFalse(landed.cacheHit)
    }

    /// Suppression is applied to the returned copy, never baked into the cache,
    /// so toggling it during an Undo-send window must not cost a reload.
    func testDraftSuppressionChangeStillHitsTheCache() async throws {
        let pool = try makeMailPool()
        try await pool.write { db in
            _ = try SyncEngine.upsertPending(
                db, items: [
                    .init(message: self.fixtureMessage(id: "m1", labels: "INBOX"),
                          attachments: []),
                    .init(message: self.fixtureMessage(id: "d1", labels: "DRAFT"),
                          attachments: []),
                ])
        }
        let repository = ThreadDetailRepository(db: pool)
        let revisions = ThreadContentRevisions()
        let revision = revisions.revision(of: "thread")
        _ = await repository.payload(
            threadId: "thread", suppressingDrafts: [], revision: revision)

        let suppressed = await repository.payload(
            threadId: "thread", suppressingDrafts: ["d1"], revision: revision)

        XCTAssertTrue(suppressed.cacheHit)
        XCTAssertEqual(suppressed.payload.messages.map(\.id), ["m1"])
    }

    private func makeMailPool() throws -> DatabasePool {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("thread-detail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("mail.sqlite").path)
        try AppDatabase.migrator.migrate(pool)
        try pool.write { db in
            try Account(
                id: "me@example.com", displayName: "Me", historyId: nil,
                lastSyncAt: nil, senderName: "Me").insert(db)
        }
        return pool
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

    /// The VIP remote-image gate reads `message.senderAuth` from the pane's
    /// Message. The initial frame comes from fetchPayload's custom SELECT,
    /// which must project the column explicitly — otherwise the verdict is
    /// nil on every auto-expanded message and the gate never engages.
    func testFetchPayloadProjectsSenderAuth() async throws {
        let pool = try makeMailPool()
        try await pool.write { db in
            var message = self.fixtureMessage(id: "m1", labels: "INBOX")
            message.senderAuth = false
            _ = try SyncEngine.upsertPending(
                db, items: [.init(message: message, attachments: [])])
        }
        let payload = try await pool.read { db in
            try ThreadDetailRepository.fetchPayload(threadId: "thread", db: db)
        }
        XCTAssertEqual(payload.messages.map(\.senderAuth), [false])
    }

    private func fixtureAttachment(messageId: String) -> AttachmentRow {
        AttachmentRow(
            id: nil, messageId: messageId, gmailAttachmentId: "att",
            filename: "file.txt", mimeType: "text/plain", size: 1)
    }
}
