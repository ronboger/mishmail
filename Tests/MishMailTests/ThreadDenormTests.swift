import XCTest
import GRDB

/// Denormalized thread flags + VIP/count helpers that the list/badge hot
/// paths rely on after v16.
final class ThreadDenormTests: XCTestCase {

    // MARK: - syncFlagsFromLabelIds

    func testSyncFlagsFromLabelIdsSetsAllDenormBooleans() {
        var t = MailThread(
            id: "a:t1", accountId: "a", gmailThreadId: "t1",
            subject: "s", snippet: "sn", fromDisplay: "F",
            lastDate: Date(), isUnread: false, isStarred: false,
            inInbox: false, inTrash: false,
            labelIds: "INBOX STARRED SENT DRAFT CATEGORY_PROMOTIONS CATEGORY_SOCIAL SPAM",
            snoozeUntil: nil, participants: "F", messageCount: 1,
            hasAttachment: false, reminderAt: nil)
        t.syncFlagsFromLabelIds()
        XCTAssertTrue(t.isStarred)
        XCTAssertTrue(t.inInbox)
        XCTAssertFalse(t.inTrash)
        XCTAssertTrue(t.inSent)
        XCTAssertTrue(t.inDrafts)
        XCTAssertTrue(t.inPromotions)
        XCTAssertTrue(t.inSocial)
        XCTAssertTrue(t.inSpam)
    }

    func testSyncFlagsFromLabelIdsClearsWhenLabelsRemoved() {
        var t = MailThread(
            id: "a:t1", accountId: "a", gmailThreadId: "t1",
            subject: "s", snippet: "sn", fromDisplay: "F",
            lastDate: Date(), isUnread: false, isStarred: true,
            inInbox: true, inTrash: false,
            labelIds: "INBOX STARRED SENT CATEGORY_PROMOTIONS",
            snoozeUntil: nil, participants: "F", messageCount: 1,
            hasAttachment: false, reminderAt: nil,
            inSent: true, inDrafts: false, inPromotions: true, inSocial: false)
        // Drop promo + star + sent; leave inbox.
        t.labelIds = "INBOX"
        t.syncFlagsFromLabelIds()
        XCTAssertFalse(t.isStarred)
        XCTAssertTrue(t.inInbox)
        XCTAssertFalse(t.inSent)
        XCTAssertFalse(t.inPromotions)
        XCTAssertFalse(t.inDrafts)
        XCTAssertFalse(t.inSocial)
        XCTAssertFalse(t.inSpam)
    }

    func testSyncFlagsFromLabelIdsDoesNotFalseMatchPartialTokens() {
        // User label "RESENT" must not flip inSent.
        var t = MailThread(
            id: "a:t1", accountId: "a", gmailThreadId: "t1",
            subject: "s", snippet: "sn", fromDisplay: "F",
            lastDate: Date(), isUnread: false, isStarred: false,
            inInbox: true, inTrash: false,
            labelIds: "INBOX Label_RESENT",
            snoozeUntil: nil, participants: "F", messageCount: 1,
            hasAttachment: false, reminderAt: nil)
        t.syncFlagsFromLabelIds()
        XCTAssertFalse(t.inSent)
        XCTAssertFalse(t.inDrafts)
        XCTAssertTrue(t.inInbox)
    }

    // MARK: - applyLabelMutation

    func testApplyLabelMutationPreservesOptimisticStar() {
        // toggleStar sets only isStarred; a trash before sync must not wipe it.
        var t = MailThread(
            id: "a:t1", accountId: "a", gmailThreadId: "t1",
            subject: "s", snippet: "sn", fromDisplay: "F",
            lastDate: Date(), isUnread: false, isStarred: true,
            inInbox: true, inTrash: false,
            labelIds: "INBOX",
            snoozeUntil: nil, participants: "F", messageCount: 1,
            hasAttachment: false, reminderAt: nil)
        t.applyLabelMutation(add: ["TRASH"], remove: ["INBOX"])
        XCTAssertTrue(t.isStarred)
        XCTAssertTrue(t.labels.contains("STARRED"))
        XCTAssertTrue(t.inTrash)
        XCTAssertFalse(t.inInbox)
        XCTAssertFalse(t.labels.contains("INBOX"))
    }

    func testApplyLabelMutationDoesNotResurrectOptimisticUnstar() {
        // Optimistic unstar: labelIds still has STARRED but isStarred is false.
        var t = MailThread(
            id: "a:t1", accountId: "a", gmailThreadId: "t1",
            subject: "s", snippet: "sn", fromDisplay: "F",
            lastDate: Date(), isUnread: false, isStarred: false,
            inInbox: true, inTrash: false,
            labelIds: "INBOX STARRED",
            snoozeUntil: nil, participants: "F", messageCount: 1,
            hasAttachment: false, reminderAt: nil)
        t.applyLabelMutation(add: ["TRASH"], remove: ["INBOX"])
        XCTAssertFalse(t.isStarred)
        XCTAssertFalse(t.labels.contains("STARRED"))
        XCTAssertTrue(t.inTrash)
    }

    func testApplyLabelMutationPreservesOptimisticArchive() {
        // archive/snooze clear inInbox without touching labelIds; a spam
        // mark's undo must not resurrect INBOX from stale labelIds... but the
        // undo explicitly adds INBOX, so test the non-undo direction: a
        // mutation that doesn't touch INBOX keeps the archived state.
        var t = MailThread(
            id: "a:t1", accountId: "a", gmailThreadId: "t1",
            subject: "s", snippet: "sn", fromDisplay: "F",
            lastDate: Date(), isUnread: false, isStarred: false,
            inInbox: false, inTrash: false,
            labelIds: "INBOX",
            snoozeUntil: nil, participants: "F", messageCount: 1,
            hasAttachment: false, reminderAt: nil)
        t.applyLabelMutation(add: ["TRASH"])
        XCTAssertFalse(t.inInbox)
        XCTAssertFalse(t.labels.contains("INBOX"))
        XCTAssertTrue(t.inTrash)
    }

    // MARK: - Aggregate sidebar counts (in-memory DB)

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        return q
    }

    private func insertThread(_ db: Database, id: String, account: String,
                              unread: Bool, inbox: Bool, trash: Bool = false,
                              starred: Bool = false, drafts: Bool = false,
                              promotions: Bool = false, social: Bool = false,
                              spam: Bool = false,
                              snooze: Date? = nil, reminder: Date? = nil) throws {
        let t = MailThread(
            id: "\(account):\(id)", accountId: account, gmailThreadId: id,
            subject: "s", snippet: "sn", fromDisplay: "F",
            lastDate: Date(), isUnread: unread, isStarred: starred,
            inInbox: inbox, inTrash: trash,
            labelIds: "INBOX", snoozeUntil: snooze, participants: "F",
            messageCount: 1, hasAttachment: false, reminderAt: reminder,
            inSent: false, inDrafts: drafts, inPromotions: promotions,
            inSocial: social, inSpam: spam, fromEmail: "f@x.com")
        try t.insert(db)
    }

    func testAggregateCountsUseDenormFlags() throws {
        let q = try makeDB()
        try q.write { db in
            try Account(id: "a@x.com", displayName: "A", historyId: nil,
                        lastSyncAt: nil, senderName: "").insert(db)
            try Account(id: "b@x.com", displayName: "B", historyId: nil,
                        lastSyncAt: nil, senderName: "").insert(db)
            // Primary account: 2 inbox unread (one promo should NOT count as inbox)
            try self.insertThread(db, id: "t1", account: "a@x.com", unread: true, inbox: true)
            try self.insertThread(db, id: "t2", account: "a@x.com", unread: true, inbox: true)
            try self.insertThread(db, id: "t3", account: "a@x.com", unread: true, inbox: true,
                                  promotions: true)
            try self.insertThread(db, id: "t4", account: "a@x.com", unread: true, inbox: true,
                                  social: true)
            try self.insertThread(db, id: "t5", account: "a@x.com", unread: false, inbox: true,
                                  starred: true)
            try self.insertThread(db, id: "t6", account: "a@x.com", unread: false, inbox: false,
                                  drafts: true)
            // Other account: one inbox unread
            try self.insertThread(db, id: "t7", account: "b@x.com", unread: true, inbox: true)
        }

        let (all, badgeAll) = try q.read {
            try SidebarCounts.fetch(db: $0, activeAccount: nil, badgeAccount: nil)
        }
        XCTAssertEqual(all["inbox"], 3)          // t1,t2,t7
        XCTAssertEqual(all["promotions"], 1)     // t3
        XCTAssertEqual(all["social"], 1)         // t4
        XCTAssertEqual(all["starred"], 1)        // t5
        XCTAssertEqual(all["drafts"], 1)         // t6
        XCTAssertEqual(badgeAll, 3)

        let (scoped, badgeScoped) = try q.read {
            try SidebarCounts.fetch(db: $0, activeAccount: "a@x.com",
                                    badgeAccount: "b@x.com")
        }
        XCTAssertEqual(scoped["inbox"], 2)       // a only
        XCTAssertEqual(badgeScoped, 1)           // b only
    }

    /// Regression: Promotions/Social unread must match gmail.com tabs
    /// (inbox + category − spam − trash), not raw Gmail CATEGORY_* label
    /// totals (which still count spam + archived). This is the SQL the
    /// sidebar uses after the API count override was removed.
    func testPromoSocialCountsExcludeSpamAndArchived() throws {
        let q = try makeDB()
        try q.write { db in
            try Account(id: "a@x.com", displayName: "A", historyId: nil,
                        lastSyncAt: nil, senderName: "").insert(db)
            // Visible in Promotions tab.
            try self.insertThread(db, id: "promo", account: "a@x.com",
                                  unread: true, inbox: true, promotions: true)
            // Gmail keeps CATEGORY_PROMOTIONS on spam — must not badge.
            try self.insertThread(db, id: "spam", account: "a@x.com",
                                  unread: true, inbox: false, promotions: true, spam: true)
            // Archived promo — not in Gmail's Promotions tab.
            try self.insertThread(db, id: "arch", account: "a@x.com",
                                  unread: true, inbox: false, promotions: true)
            // Visible in Social tab.
            try self.insertThread(db, id: "social", account: "a@x.com",
                                  unread: true, inbox: true, social: true)
            try self.insertThread(db, id: "socialSpam", account: "a@x.com",
                                  unread: true, inbox: false, social: true, spam: true)
        }

        let (counts, _) = try q.read {
            try SidebarCounts.fetch(db: $0, activeAccount: nil, badgeAccount: nil)
        }
        XCTAssertEqual(counts["promotions"], 1, "only in-inbox non-spam promotions")
        XCTAssertEqual(counts["social"], 1, "only in-inbox non-spam social")
        XCTAssertEqual(counts["inbox"], 0, "category mail stays out of primary inbox badge")
    }

    // MARK: - VIP any-message matching

    /// Mirrors MailStore.computeVIPThreadIds: denorm fromEmail is a positive
    /// short-circuit only; non-hits still scan every message From.
    private func computeVIPThreadIds(threads: [MailThread], activeVIP: Set<String>,
                                     db: Database) throws -> Set<String> {
        guard !activeVIP.isEmpty, !threads.isEmpty else { return [] }
        var hits = Set<String>()
        var needScan: [String] = []
        for t in threads {
            if !t.fromEmail.isEmpty, activeVIP.contains(t.fromEmail) {
                hits.insert(t.id)
            } else {
                needScan.append(t.id)
            }
        }
        guard !needScan.isEmpty else { return hits }
        let placeholders = needScan.map { _ in "?" }.joined(separator: ",")
        let rows = try Row.fetchAll(db, sql: """
            SELECT DISTINCT threadId, fromHeader FROM message
            WHERE threadId IN (\(placeholders))
            """, arguments: StatementArguments(needScan))
        for row in rows {
            let header: String = row["fromHeader"]
            if activeVIP.contains(MessageParser.emailAddress(header).lowercased()) {
                hits.insert(row["threadId"])
            }
        }
        return hits
    }

    func testVIPShortCircuitAndEmptyFromEmailScan() throws {
        let q = try makeDB()
        let account = "a@x.com"
        try q.write { db in
            try Account(id: account, displayName: "A", historyId: nil,
                        lastSyncAt: nil, senderName: "").insert(db)
            // Thread with denorm fromEmail filled (newest is VIP).
            let filled = MailThread(
                id: "\(account):t1", accountId: account, gmailThreadId: "t1",
                subject: "s", snippet: "", fromDisplay: "Vip",
                lastDate: Date(), isUnread: true, isStarred: false,
                inInbox: true, inTrash: false, labelIds: "INBOX",
                snoozeUntil: nil, participants: "Vip", messageCount: 1,
                hasAttachment: false, reminderAt: nil,
                fromEmail: "vip@x.com")
            try filled.insert(db)
            // Thread with empty fromEmail — must scan messages.
            let empty = MailThread(
                id: "\(account):t2", accountId: account, gmailThreadId: "t2",
                subject: "s", snippet: "", fromDisplay: "Other",
                lastDate: Date(), isUnread: true, isStarred: false,
                inInbox: true, inTrash: false, labelIds: "INBOX",
                snoozeUntil: nil, participants: "Other", messageCount: 1,
                hasAttachment: false, reminderAt: nil, fromEmail: "")
            try empty.insert(db)
            try Message(
                id: "\(account):m2", accountId: account, gmailId: "m2",
                threadId: "\(account):t2",
                fromHeader: "Other VIP <other@x.com>", toHeader: account,
                ccHeader: "", bccHeader: "", subject: "s", date: Date(),
                snippet: "", bodyText: "body", bodyHTML: nil,
                messageIdHeader: "", referencesHeader: "", labelIds: "INBOX",
                isUnread: true, hasAttachment: false).insert(db)
            // Non-VIP with empty fromEmail (should not match).
            let noise = MailThread(
                id: "\(account):t3", accountId: account, gmailThreadId: "t3",
                subject: "s", snippet: "", fromDisplay: "Noise",
                lastDate: Date(), isUnread: true, isStarred: false,
                inInbox: true, inTrash: false, labelIds: "INBOX",
                snoozeUntil: nil, participants: "Noise", messageCount: 1,
                hasAttachment: false, reminderAt: nil, fromEmail: "")
            try noise.insert(db)
            try Message(
                id: "\(account):m3", accountId: account, gmailId: "m3",
                threadId: "\(account):t3",
                fromHeader: "Noise <noise@x.com>", toHeader: account,
                ccHeader: "", bccHeader: "", subject: "s", date: Date(),
                snippet: "", bodyText: "body", bodyHTML: nil,
                messageIdHeader: "", referencesHeader: "", labelIds: "INBOX",
                isUnread: true, hasAttachment: false).insert(db)
        }

        let threads = try q.read { try MailThread.fetchAll($0) }
        let hits = try q.read {
            try self.computeVIPThreadIds(
                threads: threads,
                activeVIP: ["vip@x.com", "other@x.com"],
                db: $0)
        }
        XCTAssertEqual(hits, ["\(account):t1", "\(account):t2"])
    }

    /// Newest From is the user; an older message is from a VIP — thread must
    /// still pin (replying must not drop Priority).
    func testVIPMatchesOlderParticipantNotJustNewest() throws {
        let q = try makeDB()
        let account = "me@x.com"
        try q.write { db in
            try Account(id: account, displayName: "Me", historyId: nil,
                        lastSyncAt: nil, senderName: "").insert(db)
            let thread = MailThread(
                id: "\(account):t1", accountId: account, gmailThreadId: "t1",
                subject: "s", snippet: "", fromDisplay: "Me",
                lastDate: Date(), isUnread: false, isStarred: false,
                inInbox: true, inTrash: false, labelIds: "INBOX SENT",
                snoozeUntil: nil, participants: "Vip .. me", messageCount: 2,
                hasAttachment: false, reminderAt: nil,
                fromEmail: "me@x.com")  // newest is self, not VIP
            try thread.insert(db)
            try Message(
                id: "\(account):m1", accountId: account, gmailId: "m1",
                threadId: "\(account):t1",
                fromHeader: "VIP Person <vip@x.com>", toHeader: account,
                ccHeader: "", bccHeader: "", subject: "s",
                date: Date().addingTimeInterval(-3600),
                snippet: "", bodyText: "hi", bodyHTML: nil,
                messageIdHeader: "", referencesHeader: "", labelIds: "INBOX",
                isUnread: false, hasAttachment: false).insert(db)
            try Message(
                id: "\(account):m2", accountId: account, gmailId: "m2",
                threadId: "\(account):t1",
                fromHeader: "Me <me@x.com>", toHeader: "vip@x.com",
                ccHeader: "", bccHeader: "", subject: "Re: s",
                date: Date(),
                snippet: "", bodyText: "re", bodyHTML: nil,
                messageIdHeader: "", referencesHeader: "", labelIds: "SENT",
                isUnread: false, hasAttachment: false).insert(db)
        }

        let threads = try q.read { try MailThread.fetchAll($0) }
        let hits = try q.read {
            try self.computeVIPThreadIds(
                threads: threads, activeVIP: ["vip@x.com"], db: $0)
        }
        XCTAssertEqual(hits, ["\(account):t1"],
                       "older VIP participant must pin even when newest From is self")
    }

    /// Blocklist matching: any message From (not only denorm newest).
    func testBlocklistMatchesOlderParticipant() throws {
        let q = try makeDB()
        let account = "me@x.com"
        let blocked = "spam@x.com"
        try q.write { db in
            try Account(id: account, displayName: "Me", historyId: nil,
                        lastSyncAt: nil, senderName: "").insert(db)
            // Newest From is self; older message is from blocked sender.
            let thread = MailThread(
                id: "\(account):t1", accountId: account, gmailThreadId: "t1",
                subject: "s", snippet: "", fromDisplay: "Me",
                lastDate: Date(), isUnread: false, isStarred: false,
                inInbox: true, inTrash: false, labelIds: "INBOX SENT",
                snoozeUntil: nil, participants: "Spam .. me", messageCount: 2,
                hasAttachment: false, reminderAt: nil,
                fromEmail: "me@x.com")
            try thread.insert(db)
            try Message(
                id: "\(account):m1", accountId: account, gmailId: "m1",
                threadId: "\(account):t1",
                fromHeader: "Spam <\(blocked)>", toHeader: account,
                ccHeader: "", bccHeader: "", subject: "s",
                date: Date().addingTimeInterval(-3600),
                snippet: "", bodyText: "hi", bodyHTML: nil,
                messageIdHeader: "", referencesHeader: "", labelIds: "INBOX",
                isUnread: false, hasAttachment: false).insert(db)
            try Message(
                id: "\(account):m2", accountId: account, gmailId: "m2",
                threadId: "\(account):t1",
                fromHeader: "Me <me@x.com>", toHeader: blocked,
                ccHeader: "", bccHeader: "", subject: "Re: s",
                date: Date(),
                snippet: "", bodyText: "re", bodyHTML: nil,
                messageIdHeader: "", referencesHeader: "", labelIds: "SENT",
                isUnread: false, hasAttachment: false).insert(db)
            // Control: inbox thread with no blocked sender.
            let clean = MailThread(
                id: "\(account):t2", accountId: account, gmailThreadId: "t2",
                subject: "ok", snippet: "", fromDisplay: "Friend",
                lastDate: Date(), isUnread: true, isStarred: false,
                inInbox: true, inTrash: false, labelIds: "INBOX",
                snoozeUntil: nil, participants: "Friend", messageCount: 1,
                hasAttachment: false, reminderAt: nil,
                fromEmail: "friend@x.com")
            try clean.insert(db)
            try Message(
                id: "\(account):m3", accountId: account, gmailId: "m3",
                threadId: "\(account):t2",
                fromHeader: "Friend <friend@x.com>", toHeader: account,
                ccHeader: "", bccHeader: "", subject: "ok", date: Date(),
                snippet: "", bodyText: "hi", bodyHTML: nil,
                messageIdHeader: "", referencesHeader: "", labelIds: "INBOX",
                isUnread: true, hasAttachment: false).insert(db)
        }

        let blockedSet: Set<String> = [blocked]
        let hitIds = try q.read { db -> Set<String> in
            var hits = Set<String>()
            // Fast path: denorm fromEmail.
            let byEmail = try MailThread
                .filter(Column("inInbox") == true && Column("inTrash") == false)
                .filter(Column("fromEmail") != "")
                .filter(Array(blockedSet).contains(Column("fromEmail")))
                .fetchAll(db)
            hits.formUnion(byEmail.map(\.id))
            // Scan remaining for any-message match.
            let remaining = try String.fetchAll(db, sql: """
                SELECT id FROM thread WHERE inInbox = 1 AND inTrash = 0
                """)
            let toScan = remaining.filter { !hits.contains($0) }
            if !toScan.isEmpty {
                let placeholders = toScan.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT DISTINCT message.threadId AS threadId, message.fromHeader AS fromHeader
                    FROM message WHERE message.threadId IN (\(placeholders))
                    """, arguments: StatementArguments(toScan))
                for row in rows {
                    let header: String = row["fromHeader"]
                    if blockedSet.contains(MessageParser.emailAddress(header).lowercased()) {
                        hits.insert(row["threadId"])
                    }
                }
            }
            return hits
        }
        XCTAssertEqual(hitIds, ["\(account):t1"],
                       "blocked older participant must match even when newest From is self")
        XCTAssertFalse(hitIds.contains("\(account):t2"))
    }

    /// Optimistic label mutation keeps denorm flags coherent with labelIds.
    func testSyncFlagsAfterOptimisticLabelMutation() {
        var t = MailThread(
            id: "a:t1", accountId: "a", gmailThreadId: "t1",
            subject: "s", snippet: "sn", fromDisplay: "F",
            lastDate: Date(), isUnread: false, isStarred: false,
            inInbox: true, inTrash: false,
            labelIds: "INBOX",
            snoozeUntil: nil, participants: "F", messageCount: 1,
            hasAttachment: false, reminderAt: nil)
        t.syncFlagsFromLabelIds()
        // Toggle CATEGORY_PROMOTIONS on (mirrors toggleLabel).
        var labels = Set(t.labels)
        labels.insert("CATEGORY_PROMOTIONS")
        labels.insert("SENT")
        t.labelIds = labels.sorted().joined(separator: " ")
        t.syncFlagsFromLabelIds()
        XCTAssertTrue(t.inPromotions)
        XCTAssertTrue(t.inSent)
        XCTAssertTrue(t.inInbox)
        // Blocklist / markSpam-style SPAM move: promotions label stays, but
        // inSpam flips so Promotions/Social list queries can exclude it.
        labels.remove("INBOX")
        labels.insert("SPAM")
        t.labelIds = labels.sorted().joined(separator: " ")
        t.syncFlagsFromLabelIds()
        XCTAssertFalse(t.inInbox)
        XCTAssertTrue(t.inPromotions)
        XCTAssertTrue(t.inSpam)
        XCTAssertTrue(t.inSent)
    }
}
