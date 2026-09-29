import XCTest
import GRDB

/// Planning multi-select label edits as `messages.batchModify` calls: which
/// threads may batch (only locally complete ones), how they group per
/// account and label set, and how ids chunk under Gmail's 1000-id cap.
final class BulkThreadModifyTests: XCTestCase {
    private typealias B = BulkThreadModify
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let full = B.Coverage(windowDays: 90, backfilled: true)

    private func msg(_ id: String, daysAgo: Double = 1, labels: String = "INBOX",
                     references: String = "", subject: String = "Hello") -> B.MessageFacts {
        B.MessageFacts(gmailId: id, date: now.addingTimeInterval(-daysAgo * 86_400),
                       labelIds: labels, referencesHeader: references, subject: subject)
    }

    /// A root plus `replies - 1` replies, all recent.
    private func thread(_ id: String, account: String = "a@x.com", replies: Int = 1,
                        add: [String] = [], remove: [String] = ["INBOX", "UNREAD"]) -> B.Target {
        var messages = [msg("\(id)-0", daysAgo: 5)]
        for i in 1..<max(replies, 1) {
            messages.append(msg("\(id)-\(i)", daysAgo: 1, references: "<root@x>", subject: "Re: Hello"))
        }
        return B.Target(threadId: "\(account):\(id)", accountId: account,
                        add: add, remove: remove, messages: messages)
    }

    // MARK: - Completeness (fallback decision)

    func testRecentRootedThreadIsComplete() {
        let messages = [msg("m1", daysAgo: 10),
                        msg("m2", daysAgo: 2, references: "<m1@x>", subject: "Re: Hello")]
        XCTAssertTrue(B.isLocallyComplete(messages, coverage: full, now: now))
    }

    func testOldestLocalReplyMeansEarlierMessagesMayBeMissing() {
        // The root predates the window: only its replies were ever fetched.
        let messages = [msg("m2", daysAgo: 2, references: "<m1@x>", subject: "Re: Hello")]
        XCTAssertFalse(B.isLocallyComplete(messages, coverage: full, now: now))
    }

    func testReplyPrefixWithoutReferencesIsNotTrustedAsRoot() {
        let messages = [msg("m2", daysAgo: 2, subject: "RE: Budget")]
        XCTAssertFalse(B.isLocallyComplete(messages, coverage: full, now: now))
    }

    func testRootOutsideWindowIsNotComplete() {
        // An old starred root is kept locally, but the replies between it and
        // the window start never were.
        let messages = [msg("m1", daysAgo: 200, labels: "STARRED"),
                        msg("m3", daysAgo: 2, references: "<m1@x>", subject: "Re: Hello")]
        XCTAssertFalse(B.isLocallyComplete(messages, coverage: full, now: now))
    }

    func testEverythingWindowIgnoresAge() {
        let all = B.Coverage(windowDays: 0, backfilled: true)
        XCTAssertTrue(B.isLocallyComplete([msg("m1", daysAgo: 2_000)], coverage: all, now: now))
    }

    func testUnfinishedBackfillOrNothingWindowIsNotComplete() {
        let pending = B.Coverage(windowDays: 90, backfilled: false)
        XCTAssertFalse(B.isLocallyComplete([msg("m1")], coverage: pending, now: now))
        let nothing = B.Coverage(windowDays: SyncEngine.windowNothing, backfilled: true)
        XCTAssertFalse(B.isLocallyComplete([msg("m1")], coverage: nothing, now: now))
    }

    func testDraftOrNoMessagesIsNotComplete() {
        XCTAssertFalse(B.isLocallyComplete(
            [msg("m1"), msg("d1", labels: "DRAFT", references: "<m1@x>")],
            coverage: full, now: now))
        XCTAssertFalse(B.isLocallyComplete([], coverage: full, now: now))
    }

    // MARK: - Grouping

    func testGroupsPerAccountAndLabelSet() {
        let targets = [
            thread("t1"),
            thread("t2", account: "b@x.com"),
            thread("t3"),
            thread("t4", account: "b@x.com"),
            thread("t5", add: ["STARRED"], remove: []),
            thread("t6", add: ["STARRED"], remove: []),
        ]
        let plan = B.plan(targets, coverage: ["a@x.com": full, "b@x.com": full], now: now)
        XCTAssertEqual(plan.fallbackThreadIds, [])
        XCTAssertEqual(plan.batches.map(\.threadIds), [
            ["a@x.com:t1", "a@x.com:t3"],
            ["b@x.com:t2", "b@x.com:t4"],
            ["a@x.com:t5", "a@x.com:t6"],
        ])
        XCTAssertEqual(plan.batches[0].messageIds, ["t1-0", "t3-0"])
        XCTAssertEqual(plan.batches[0].remove, ["INBOX", "UNREAD"])
        XCTAssertEqual(plan.batches[2].add, ["STARRED"])
    }

    func testLabelOrderDoesNotSplitAGroup() {
        let plan = B.plan([thread("t1", remove: ["INBOX", "UNREAD"]),
                           thread("t2", remove: ["UNREAD", "INBOX"])],
                          coverage: ["a@x.com": full], now: now)
        XCTAssertEqual(plan.batches.count, 1)
        XCTAssertEqual(plan.batches[0].threadIds.count, 2)
    }

    func testLoneThreadInAGroupFallsBack() {
        // One thread: threads.modify (10 units) beats batchModify (50).
        let plan = B.plan([thread("t1"), thread("t2", account: "b@x.com"), thread("t3")],
                          coverage: ["a@x.com": full, "b@x.com": full], now: now)
        XCTAssertEqual(plan.batches.map(\.threadIds), [["a@x.com:t1", "a@x.com:t3"]])
        XCTAssertEqual(plan.fallbackThreadIds, ["b@x.com:t2"])
    }

    func testIncompleteEmptyAndUnknownAccountThreadsFallBack() {
        var partial = thread("t2")
        partial.messages = [msg("t2-1", references: "<r@x>", subject: "Re: x")]
        let targets = [thread("t1"), partial, thread("t3"),
                       thread("t4", remove: []),
                       thread("t5", account: "c@x.com"), thread("t6", account: "c@x.com")]
        let plan = B.plan(targets, coverage: ["a@x.com": full], now: now)
        XCTAssertEqual(plan.batches.map(\.threadIds), [["a@x.com:t1", "a@x.com:t3"]])
        XCTAssertEqual(plan.fallbackThreadIds,
                       ["a@x.com:t2", "a@x.com:t4", "c@x.com:t5", "c@x.com:t6"])
    }

    // MARK: - Chunking

    func testChunksAtMaxIdsWithoutSplittingThreads() {
        // 3 messages each, cap 7: two threads (6 ids) per call.
        let targets = (1...5).map { thread("t\($0)", replies: 3) }
        let plan = B.plan(targets, coverage: ["a@x.com": full], now: now, maxIds: 7)
        XCTAssertEqual(plan.batches.map(\.threadIds.count), [2, 2, 1])
        XCTAssertTrue(plan.batches.allSatisfy { $0.messageIds.count <= 7 })
        XCTAssertEqual(plan.batches.flatMap(\.messageIds).count, 15)
    }

    func testChunksAtGmailCap() {
        let targets = (1...1_500).map { thread("t\($0)") }
        let plan = B.plan(targets, coverage: ["a@x.com": full], now: now)
        XCTAssertEqual(GmailClient.batchModifyMaxIds, 1000)
        XCTAssertEqual(plan.batches.map(\.messageIds.count), [1000, 500])
    }

    func testThreadLargerThanCapFallsBack() {
        let plan = B.plan([thread("big", replies: 8), thread("t1"), thread("t2")],
                          coverage: ["a@x.com": full], now: now, maxIds: 5)
        XCTAssertEqual(plan.fallbackThreadIds, ["a@x.com:big"])
        XCTAssertEqual(plan.batches.map(\.threadIds), [["a@x.com:t1", "a@x.com:t2"]])
    }

    // MARK: - Database reads

    func testMessageFactsAndQueuedIdsReadFromDatabase() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: "a@x.com", displayName: "A", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            for (id, thread) in [("m1", "t1"), ("m2", "t1"), ("m3", "t2")] {
                try Message(id: "a@x.com:\(id)", accountId: "a@x.com", gmailId: id,
                            threadId: "a@x.com:\(thread)", fromHeader: "x@y.com",
                            toHeader: "", ccHeader: "", bccHeader: "", subject: "S", date: now,
                            snippet: "", bodyText: "", bodyHTML: nil,
                            messageIdHeader: "", referencesHeader: id == "m2" ? "<m1>" : "",
                            labelIds: "INBOX", isUnread: false, hasAttachment: false)
                    .save(db)
            }
            try PendingThreadOp.enqueue(db, accountId: "a@x.com", gmailThreadId: "t2",
                                        change: .modify(add: ["STARRED"]))
        }
        try q.read { db in
            let facts = try B.messageFacts(db, threadIds: ["a@x.com:t1", "a@x.com:t2", "a@x.com:t9"])
            XCTAssertEqual(Set(facts["a@x.com:t1"]?.map(\.gmailId) ?? []), ["m1", "m2"])
            XCTAssertEqual(facts["a@x.com:t2"]?.map(\.gmailId), ["m3"])
            XCTAssertNil(facts["a@x.com:t9"])
            XCTAssertEqual(try B.queuedThreadIds(db), ["a@x.com:t2"])
        }
    }
}
