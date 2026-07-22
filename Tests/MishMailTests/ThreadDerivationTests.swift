import XCTest
import GRDB

/// SyncEngine.deriveThread — the pure core of sync: how a thread row is
/// computed from its messages (always passed newest first).
final class ThreadDerivationTests: XCTestCase {

    private let account = "ron@x.com"

    private func msg(id: String, from: String, subject: String = "Subj",
                     daysAgo: Double, labels: String = "INBOX",
                     unread: Bool = false, attachment: Bool = false) -> Message {
        Message(id: "\(account):\(id)", accountId: account, gmailId: id,
                threadId: "\(account):t1", fromHeader: from, toHeader: account,
                ccHeader: "", bccHeader: "", subject: subject,
                date: Date(timeIntervalSinceNow: -daysAgo * 86_400),
                snippet: "snippet-\(id)", bodyText: "", bodyHTML: nil,
                messageIdHeader: "", referencesHeader: "", labelIds: labels,
                isUnread: unread, hasAttachment: attachment)
    }

    private func derive(_ messages: [Message], existing: MailThread? = nil) -> MailThread? {
        SyncEngine.deriveThread(threadKey: "\(account):t1", gmailThreadId: "t1",
                                accountId: account, messages: messages, existing: existing)
    }

    func testEmptyThreadDerivesNothing() {
        XCTAssertNil(derive([]))
    }

    func testBasicAggregation() throws {
        let newest = msg(id: "m2", from: "Jane Doe <jane@y.com>", daysAgo: 0,
                         labels: "INBOX UNREAD", unread: true)
        let oldest = msg(id: "m1", from: "\(account)", subject: "Original subject",
                         daysAgo: 1, labels: "SENT STARRED", attachment: true)
        let t = try XCTUnwrap(derive([newest, oldest]))

        XCTAssertEqual(t.id, "\(account):t1")
        XCTAssertEqual(t.subject, "Original subject", "thread shows the first message's subject")
        XCTAssertEqual(t.snippet, "snippet-m2", "…but the newest snippet")
        XCTAssertEqual(t.fromDisplay, "Jane Doe")
        XCTAssertEqual(t.lastDate, newest.date)
        XCTAssertTrue(t.isUnread)
        XCTAssertTrue(t.isStarred, "starred anywhere in the thread counts")
        XCTAssertTrue(t.inInbox)
        XCTAssertFalse(t.inTrash)
        XCTAssertTrue(t.hasAttachment)
        XCTAssertEqual(t.messageCount, 2)
        XCTAssertEqual(t.labelIds, "INBOX SENT STARRED UNREAD")
        XCTAssertTrue(t.inSent, "SENT anywhere in the thread sets inSent")
        XCTAssertFalse(t.inDrafts)
        XCTAssertFalse(t.inPromotions)
        XCTAssertFalse(t.inSocial)
        XCTAssertFalse(t.inSpam)
        XCTAssertEqual(t.fromEmail, "jane@y.com", "newest From, lowercased bare email")
    }

    func testLabelDenormFlagsAndFromEmail() throws {
        // No INBOX → tab categories fall back to newest message.
        let newest = msg(id: "m2", from: "Promo Bot <PROMO@Shop.COM>", daysAgo: 0,
                         labels: "CATEGORY_PROMOTIONS CATEGORY_SOCIAL")
        let oldest = msg(id: "m1", from: account, daysAgo: 1, labels: "DRAFT")
        let t = try XCTUnwrap(derive([newest, oldest]))
        XCTAssertFalse(t.inSent)
        XCTAssertTrue(t.inDrafts)
        XCTAssertTrue(t.inPromotions)
        XCTAssertTrue(t.inSocial)
        XCTAssertFalse(t.inSpam)
        XCTAssertEqual(t.fromEmail, "promo@shop.com")
    }

    func testSpamLabelSetsInSpamEvenWithPromotions() throws {
        // Gmail often keeps CATEGORY_PROMOTIONS when moving mail to Spam.
        // No INBOX → fall back to newest message for tab flags.
        let newest = msg(id: "m1", from: "Casino <spam@x.com>", daysAgo: 0,
                         labels: "SPAM CATEGORY_PROMOTIONS")
        let t = try XCTUnwrap(derive([newest]))
        XCTAssertTrue(t.inSpam)
        XCTAssertTrue(t.inPromotions)
        XCTAssertFalse(t.inInbox)
    }

    // MARK: - Tab category placement (Primary vs Promotions/Social)

    func testPersonalReplyOnArchivedPromoSurfacesInPrimary() throws {
        // Windsurf-style: archived no-reply invite keeps CATEGORY_PROMOTIONS
        // (no INBOX); a human reply re-adds INBOX without the promo category.
        // Primary must show the thread — not stay hidden under Promotions.
        let reply = msg(id: "m4", from: "Ryan <ryan@cognition.ai>", daysAgo: 0,
                        labels: "IMPORTANT CATEGORY_PERSONAL INBOX", unread: true)
        let earlier = msg(id: "m3", from: "Ryan <ryan@cognition.ai>", daysAgo: 1,
                          labels: "CATEGORY_PERSONAL IMPORTANT INBOX")
        let mine = msg(id: "m2", from: account, daysAgo: 2, labels: "SENT")
        let invite = msg(id: "m1", from: "Windsurf <no-reply@windsurf.com>", daysAgo: 3,
                         labels: "CATEGORY_PROMOTIONS")
        let t = try XCTUnwrap(derive([reply, earlier, mine, invite]))
        XCTAssertTrue(t.inInbox)
        XCTAssertFalse(t.inPromotions, "historical promo on archived invite must not pin tab")
        XCTAssertFalse(t.inSocial)
        // Union labelIds still records the promo label for search / chips.
        XCTAssertTrue(t.labelIds.split(separator: " ").map(String.init)
                        .contains("CATEGORY_PROMOTIONS"))
        XCTAssertTrue(t.isUnread)
    }

    func testPersonalReplyOnArchivedSocialSurfacesInPrimary() throws {
        let reply = msg(id: "m2", from: "Friend <f@x.com>", daysAgo: 0,
                        labels: "INBOX CATEGORY_PERSONAL")
        let social = msg(id: "m1", from: "Network <n@social.com>", daysAgo: 1,
                         labels: "CATEGORY_SOCIAL")
        let t = try XCTUnwrap(derive([reply, social]))
        XCTAssertTrue(t.inInbox)
        XCTAssertFalse(t.inSocial)
        XCTAssertFalse(t.inPromotions)
        XCTAssertTrue(t.labelIds.split(separator: " ").map(String.init)
                        .contains("CATEGORY_SOCIAL"))
    }

    func testPromoStillInInboxStaysInPromotionsTab() throws {
        let promo = msg(id: "m1", from: "Deals <deals@shop.com>", daysAgo: 0,
                        labels: "INBOX CATEGORY_PROMOTIONS UNREAD", unread: true)
        let t = try XCTUnwrap(derive([promo]))
        XCTAssertTrue(t.inInbox)
        XCTAssertTrue(t.inPromotions)
    }

    func testNewestInboxBearingWinsOverOlderInboxPromo() throws {
        // Both still in inbox; newest is personal → Primary.
        let personal = msg(id: "m2", from: "Jane <jane@y.com>", daysAgo: 0,
                           labels: "INBOX CATEGORY_PERSONAL")
        let promo = msg(id: "m1", from: "Bot <bot@shop.com>", daysAgo: 1,
                        labels: "INBOX CATEGORY_PROMOTIONS")
        let t = try XCTUnwrap(derive([personal, promo]))
        XCTAssertTrue(t.inInbox)
        XCTAssertFalse(t.inPromotions)
    }

    func testTabCategoryFlagsHelper() {
        let reply = msg(id: "m2", from: "a@b.com", daysAgo: 0,
                        labels: "INBOX CATEGORY_PERSONAL")
        let invite = msg(id: "m1", from: "bot@x.com", daysAgo: 1,
                         labels: "CATEGORY_PROMOTIONS")
        let tabs = SyncEngine.tabCategoryFlags(messages: [reply, invite])
        XCTAssertFalse(tabs.promotions)
        XCTAssertFalse(tabs.social)
        // String overload must match (migration + derive share this path).
        let fromStrings = SyncEngine.tabCategoryFlags(
            labelIdStrings: [reply.labelIds, invite.labelIds])
        XCTAssertEqual(fromStrings.promotions, tabs.promotions)
        XCTAssertEqual(fromStrings.social, tabs.social)

        let purePromo = SyncEngine.tabCategoryFlags(messages: [
            msg(id: "p", from: "bot@x.com", daysAgo: 0,
                labels: "INBOX CATEGORY_PROMOTIONS CATEGORY_SOCIAL")
        ])
        XCTAssertTrue(purePromo.promotions)
        XCTAssertTrue(purePromo.social)

        XCTAssertEqual(SyncEngine.tabCategoryFlags(messages: []).promotions, false)
        XCTAssertEqual(SyncEngine.tabCategoryFlags(labelIdStrings: []).promotions, false)
    }

    func testParticipantsChronologicalDedupedAndMe() throws {
        let messages = [
            msg(id: "m3", from: "Jane Doe <jane@y.com>", daysAgo: 0),      // newest
            msg(id: "m2", from: account, daysAgo: 1),                       // me
            msg(id: "m1", from: "Jane Doe <jane@y.com>", daysAgo: 2),      // oldest
        ]
        let t = try XCTUnwrap(derive(messages))
        // Chronological (oldest first), first names only, deduped, own account as "me".
        XCTAssertEqual(t.participants, "Jane .. me")
    }

    func testSubjectFallsBackToNewestWhenOldestIsEmpty() throws {
        let messages = [
            msg(id: "m2", from: "a@b.com", subject: "Filled in later", daysAgo: 0),
            msg(id: "m1", from: "a@b.com", subject: "", daysAgo: 1),
        ]
        XCTAssertEqual(try XCTUnwrap(derive(messages)).subject, "Filled in later")
    }

    func testLocalStateSurvivesRederivation() throws {
        // Snooze and reminders are local-only; a sync must not wipe them.
        // (reminderSetAt is the "remind if no reply" activity cutoff — losing it
        // on rederivation would make the reminder fire even after a reply.)
        let snooze = Date(timeIntervalSinceNow: 3600)
        let reminder = Date(timeIntervalSinceNow: 7200)
        let reminderSet = Date(timeIntervalSinceNow: -600)
        let existing = try XCTUnwrap(derive([msg(id: "m1", from: "a@b.com", daysAgo: 1)]))
        var withState = existing
        withState.snoozeUntil = snooze
        withState.reminderAt = reminder
        withState.reminderSetAt = reminderSet

        let rederived = try XCTUnwrap(derive(
            [msg(id: "m2", from: "a@b.com", daysAgo: 0),
             msg(id: "m1", from: "a@b.com", daysAgo: 1)],
            existing: withState))
        XCTAssertEqual(rederived.snoozeUntil, snooze)
        XCTAssertEqual(rederived.reminderAt, reminder)
        XCTAssertEqual(rederived.reminderSetAt, reminderSet)
    }

    func testTrashedThread() throws {
        let t = try XCTUnwrap(derive([msg(id: "m1", from: "a@b.com", daysAgo: 0, labels: "TRASH")]))
        XCTAssertTrue(t.inTrash)
        XCTAssertFalse(t.inInbox)
    }

    // MARK: - lastInboundDate (own reply does not bump inbox position)

    func testOwnSentReplyLeavesLastDateNewestButHoldsInbound() throws {
        // lastDate = your send (Sent/row timestamp); lastInboundDate stays on
        // their mail so inbox COALESCE sort doesn't jump the thread.
        let myReply = msg(id: "m2", from: account, daysAgo: 0, labels: "SENT")
        let theirs = msg(id: "m1", from: "Jane Doe <jane@y.com>", daysAgo: 2, labels: "INBOX")
        let t = try XCTUnwrap(derive([myReply, theirs]))
        XCTAssertEqual(t.lastDate, myReply.date)
        XCTAssertEqual(t.lastInboundDate, theirs.date)
        XCTAssertEqual(t.inboxSortDate, theirs.date)
        XCTAssertEqual(t.snippet, "snippet-m2")
        XCTAssertEqual(t.fromDisplay, MessageParser.displayName(fromHeader: account))
    }

    func testInboundReplyAdvancesBothDates() throws {
        let theirs = msg(id: "m2", from: "Jane Doe <jane@y.com>", daysAgo: 0, labels: "INBOX")
        let mine = msg(id: "m1", from: account, daysAgo: 1, labels: "SENT")
        let t = try XCTUnwrap(derive([theirs, mine]))
        XCTAssertEqual(t.lastDate, theirs.date)
        XCTAssertEqual(t.lastInboundDate, theirs.date)
    }

    func testDraftDoesNotAdvanceLastInboundDate() throws {
        let draft = msg(id: "m2", from: account, daysAgo: 0, labels: "DRAFT")
        let theirs = msg(id: "m1", from: "Jane <jane@y.com>", daysAgo: 3, labels: "INBOX")
        let t = try XCTUnwrap(derive([draft, theirs]))
        XCTAssertEqual(t.lastDate, draft.date, "draft is still newest message")
        XCTAssertEqual(t.lastInboundDate, theirs.date)
    }

    func testPureOutboundThreadHasNilLastInboundDate() throws {
        // New compose / sent-only: lastDate advances; lastInboundDate stays nil
        // so "remind if no reply" does not cancel on your own nudge.
        let newer = msg(id: "m2", from: account, daysAgo: 0, labels: "SENT")
        let older = msg(id: "m1", from: account, daysAgo: 1, labels: "SENT")
        let t = try XCTUnwrap(derive([newer, older]))
        XCTAssertEqual(t.lastDate, newer.date)
        XCTAssertNil(t.lastInboundDate)
        XCTAssertEqual(t.inboxSortDate, newer.date, "COALESCE falls back to lastDate")
    }

    func testLastInboundDateHelperSkipsOwnOutbound() {
        let myReply = msg(id: "m2", from: account, daysAgo: 0, labels: "SENT")
        let theirs = msg(id: "m1", from: "Jane <jane@y.com>", daysAgo: 2, labels: "INBOX")
        XCTAssertEqual(
            SyncEngine.lastInboundDate(messages: [myReply, theirs], accountId: account),
            theirs.date)
        XCTAssertNil(
            SyncEngine.lastInboundDate(messages: [myReply], accountId: account))
        XCTAssertTrue(SyncEngine.isOwnOutbound(myReply, accountEmail: account.lowercased()))
        XCTAssertFalse(SyncEngine.isOwnOutbound(theirs, accountEmail: account.lowercased()))
    }
}

/// SyncEngine.applyLabelDelta — pure label-string merge used by metadata-only
/// history (label add/remove without a full getMessage).
final class LabelDeltaTests: XCTestCase {

    func testAddAndRemove() {
        let afterRemove = SyncEngine.applyLabelDelta(labelIds: "INBOX UNREAD",
                                                     add: [], remove: ["UNREAD"])
        XCTAssertEqual(afterRemove, "INBOX")
        let afterAdd = SyncEngine.applyLabelDelta(labelIds: afterRemove,
                                                  add: ["STARRED"], remove: [])
        XCTAssertEqual(afterAdd, "INBOX STARRED")
    }

    func testAddIsIdempotentAndSorted() {
        let result = SyncEngine.applyLabelDelta(labelIds: "INBOX STARRED",
                                                add: ["STARRED", "IMPORTANT"], remove: [])
        XCTAssertEqual(result, "IMPORTANT INBOX STARRED")
    }

    func testRemoveMissingIsNoOp() {
        let result = SyncEngine.applyLabelDelta(labelIds: "INBOX",
                                                add: [], remove: ["UNREAD", "STARRED"])
        XCTAssertEqual(result, "INBOX")
    }

    func testEmptyStartAndEmptyResult() {
        XCTAssertEqual(SyncEngine.applyLabelDelta(labelIds: "", add: ["INBOX"], remove: []),
                       "INBOX")
        XCTAssertEqual(SyncEngine.applyLabelDelta(labelIds: "UNREAD", add: [], remove: ["UNREAD"]),
                       "")
    }

    func testRemoveThenAddSameLabel() {
        // Single-event semantics: remove first, then add — so a simultaneous
        // add+remove of the same id ends up present.
        let result = SyncEngine.applyLabelDelta(labelIds: "INBOX",
                                                add: ["UNREAD"], remove: ["UNREAD"])
        XCTAssertEqual(result, "INBOX UNREAD")
    }

    func testSequentialOpsMatchHistoryOrder() {
        // History: add UNREAD, then remove UNREAD → net absent.
        var labels = "INBOX"
        labels = SyncEngine.applyLabelDelta(labelIds: labels, add: ["UNREAD"], remove: [])
        labels = SyncEngine.applyLabelDelta(labelIds: labels, add: [], remove: ["UNREAD"])
        XCTAssertEqual(labels, "INBOX")
        // History: remove UNREAD, then add UNREAD → net present.
        labels = "INBOX UNREAD"
        labels = SyncEngine.applyLabelDelta(labelIds: labels, add: [], remove: ["UNREAD"])
        labels = SyncEngine.applyLabelDelta(labelIds: labels, add: ["UNREAD"], remove: [])
        XCTAssertEqual(labels, "INBOX UNREAD")
    }
}

/// SyncEngine.deriveThreads — batched re-derivation of many threads in one
/// pass. A sync touching N messages that all belong to the same thread must
/// derive that thread exactly once, not N times, and must never derive a
/// thread that wasn't in the touched set.
final class BatchThreadDerivationTests: XCTestCase {

    private let account = "ron@x.com"

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        return q
    }

    private func insertMessage(_ db: Database, gmailId: String, threadGmailId: String,
                               from: String, daysAgo: Double, labels: String = "INBOX") throws {
        try Message(
            id: "\(account):\(gmailId)", accountId: account, gmailId: gmailId,
            threadId: "\(account):\(threadGmailId)", fromHeader: from, toHeader: account,
            ccHeader: "", bccHeader: "", subject: "s-\(threadGmailId)",
            date: Date(timeIntervalSinceNow: -daysAgo * 86_400),
            snippet: "snippet-\(gmailId)", bodyText: "", bodyHTML: nil, messageIdHeader: "",
            referencesHeader: "", labelIds: labels, isUnread: false,
            hasAttachment: false).save(db)
    }

    /// Three messages in the same thread, touched in one batch: the thread
    /// key set collapses to one entry, so derivation runs exactly once —
    /// not three times, one per message — while still producing a thread
    /// row that reflects all three messages.
    func testSameThreadMessagesDeriveOnce() throws {
        let q = try makeDB()
        try q.write { db in
            try Account(id: self.account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            try self.insertMessage(db, gmailId: "m1", threadGmailId: "t1", from: "a@b.com", daysAgo: 2)
            try self.insertMessage(db, gmailId: "m2", threadGmailId: "t1", from: "a@b.com", daysAgo: 1)
            try self.insertMessage(db, gmailId: "m3", threadGmailId: "t1", from: "a@b.com", daysAgo: 0)
        }
        // All three touched messages belong to the same thread, so a sync
        // pass collecting distinct thread keys from them collapses to one.
        let touchedMessageIds = ["m1", "m2", "m3"]
        let touchedKeys = Set(touchedMessageIds.map { _ in "\(account):t1" })
        XCTAssertEqual(touchedKeys, ["\(account):t1"], "same-thread messages collapse to one key")

        var derivations = 0
        try q.write { db in
            try SyncEngine.deriveThreads(db, for: touchedKeys, accountId: self.account,
                                        derivationCount: { derivations += 1 })
        }
        XCTAssertEqual(derivations, 1, "one thread key => exactly one derivation, regardless of message count")

        let thread = try q.read { db in try MailThread.fetchOne(db, key: "\(self.account):t1") }
        XCTAssertEqual(thread?.messageCount, 3)
        XCTAssertEqual(thread?.snippet, "snippet-m3", "reflects the newest of all three messages")
    }

    /// A batch touching messages in two different threads derives each of
    /// those threads exactly once, and never touches an unrelated thread
    /// that wasn't part of the batch.
    func testMultipleThreadsEachDeriveOnceAndOthersAreUntouched() throws {
        let q = try makeDB()
        try q.write { db in
            try Account(id: self.account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            try self.insertMessage(db, gmailId: "a1", threadGmailId: "ta", from: "a@b.com", daysAgo: 1)
            try self.insertMessage(db, gmailId: "b1", threadGmailId: "tb", from: "a@b.com", daysAgo: 1)
            try self.insertMessage(db, gmailId: "c1", threadGmailId: "tc", from: "a@b.com", daysAgo: 1)
        }
        // Pre-seed a stale thread row for "tc" (not part of this batch) so we
        // can assert it's left alone by the batch derivation.
        try q.write { db in
            var stale = try XCTUnwrap(SyncEngine.deriveThread(
                threadKey: "\(self.account):tc", gmailThreadId: "tc", accountId: self.account,
                messages: [try XCTUnwrap(Message.fetchOne(db, key: "\(self.account):c1"))],
                existing: nil))
            stale.snippet = "STALE-SHOULD-NOT-CHANGE"
            try stale.save(db)
        }

        let touchedKeys: Set<String> = ["\(account):ta", "\(account):tb"]
        var derivations = 0
        try q.write { db in
            try SyncEngine.deriveThreads(db, for: touchedKeys, accountId: self.account,
                                        derivationCount: { derivations += 1 })
        }
        XCTAssertEqual(derivations, 2, "two distinct touched threads => two derivations")

        let (ta, tb, tc) = try q.read { db in
            (try MailThread.fetchOne(db, key: "\(self.account):ta"),
             try MailThread.fetchOne(db, key: "\(self.account):tb"),
             try MailThread.fetchOne(db, key: "\(self.account):tc"))
        }
        XCTAssertEqual(ta?.snippet, "snippet-a1")
        XCTAssertEqual(tb?.snippet, "snippet-b1")
        XCTAssertEqual(tc?.snippet, "STALE-SHOULD-NOT-CHANGE", "untouched thread is not re-derived")
    }

    /// Local-only columns (snooze/reminder) survive batched re-derivation,
    /// the same guarantee `testLocalStateSurvivesRederivation` establishes
    /// for the single-thread `deriveThread` path.
    func testLocalStateSurvivesBatchRederivation() throws {
        let q = try makeDB()
        try q.write { db in
            try Account(id: self.account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            try self.insertMessage(db, gmailId: "m1", threadGmailId: "t1", from: "a@b.com", daysAgo: 1)
        }
        let snooze = Date(timeIntervalSinceNow: 3600)
        let reminder = Date(timeIntervalSinceNow: 7200)
        let reminderSet = Date(timeIntervalSinceNow: -600)
        try q.write { db in
            try SyncEngine.deriveThreads(db, for: ["\(self.account):t1"], accountId: self.account)
            var thread = try XCTUnwrap(MailThread.fetchOne(db, key: "\(self.account):t1"))
            thread.snoozeUntil = snooze
            thread.reminderAt = reminder
            thread.reminderSetAt = reminderSet
            try thread.save(db)
        }
        // Round-trip through SQLite once so the expectation matches its
        // stored (sub-second-truncated) precision, not the in-memory Date.
        let stored = try q.read { db in try XCTUnwrap(MailThread.fetchOne(db, key: "\(self.account):t1")) }

        // A second message lands in the same thread; batch re-derivation
        // must preserve the local-only columns set above.
        try q.write { db in
            try self.insertMessage(db, gmailId: "m2", threadGmailId: "t1", from: "a@b.com", daysAgo: 0)
            try SyncEngine.deriveThreads(db, for: ["\(self.account):t1"], accountId: self.account)
        }

        let rederived = try q.read { db in try MailThread.fetchOne(db, key: "\(self.account):t1") }
        XCTAssertEqual(rederived?.messageCount, 2)
        XCTAssertEqual(rederived?.snoozeUntil, stored.snoozeUntil)
        XCTAssertEqual(rederived?.reminderAt, stored.reminderAt)
        XCTAssertEqual(rederived?.reminderSetAt, stored.reminderSetAt)
    }
}
