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
            labelIds: "INBOX STARRED SENT DRAFT CATEGORY_PROMOTIONS CATEGORY_SOCIAL",
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
                              snooze: Date? = nil, reminder: Date? = nil) throws {
        let t = MailThread(
            id: "\(account):\(id)", accountId: account, gmailThreadId: id,
            subject: "s", snippet: "sn", fromDisplay: "F",
            lastDate: Date(), isUnread: unread, isStarred: starred,
            inInbox: inbox, inTrash: trash,
            labelIds: "INBOX", snoozeUntil: snooze, participants: "F",
            messageCount: 1, hasAttachment: false, reminderAt: reminder,
            inSent: false, inDrafts: drafts, inPromotions: promotions,
            inSocial: social, fromEmail: "f@x.com")
        try t.insert(db)
    }

    /// Mirrors MailStore.fetchSidebarCounts — kept in the test target so we
    /// can assert the aggregate SQL without compiling MailStore (AppKit).
    private func fetchSidebarCounts(
        db: Database, activeAccount: String?, badgeAccount: String?,
        now: Date = Date()
    ) throws -> (counts: [String: Int], badge: Int) {
        let row = try Row.fetchOne(db, sql: """
            SELECT
              COALESCE(SUM(CASE WHEN (?1 IS NULL OR accountId = ?1)
                AND isUnread = 1 AND inTrash = 0 AND inInbox = 1
                AND inPromotions = 0 AND inSocial = 0 THEN 1 ELSE 0 END), 0) AS inbox,
              COALESCE(SUM(CASE WHEN (?1 IS NULL OR accountId = ?1)
                AND isUnread = 1 AND inTrash = 0 AND inPromotions = 1 THEN 1 ELSE 0 END), 0) AS promotions,
              COALESCE(SUM(CASE WHEN (?1 IS NULL OR accountId = ?1)
                AND isUnread = 1 AND inTrash = 0 AND inSocial = 1 THEN 1 ELSE 0 END), 0) AS social,
              COALESCE(SUM(CASE WHEN (?1 IS NULL OR accountId = ?1)
                AND reminderAt IS NOT NULL THEN 1 ELSE 0 END), 0) AS reminders,
              COALESCE(SUM(CASE WHEN (?1 IS NULL OR accountId = ?1)
                AND isStarred = 1 AND inTrash = 0 THEN 1 ELSE 0 END), 0) AS starred,
              COALESCE(SUM(CASE WHEN (?1 IS NULL OR accountId = ?1)
                AND snoozeUntil IS NOT NULL AND snoozeUntil > ?3 AND inTrash = 0 THEN 1 ELSE 0 END), 0) AS snoozed,
              COALESCE(SUM(CASE WHEN (?1 IS NULL OR accountId = ?1)
                AND inDrafts = 1 AND inTrash = 0 THEN 1 ELSE 0 END), 0) AS drafts,
              COALESCE(SUM(CASE WHEN (?2 IS NULL OR accountId = ?2)
                AND isUnread = 1 AND inTrash = 0 AND inInbox = 1
                AND inPromotions = 0 AND inSocial = 0 THEN 1 ELSE 0 END), 0) AS badge
            FROM thread
            """, arguments: [activeAccount, badgeAccount, now])!
        return ([
            "inbox": row["inbox"],
            "promotions": row["promotions"],
            "social": row["social"],
            "reminders": row["reminders"],
            "starred": row["starred"],
            "snoozed": row["snoozed"],
            "drafts": row["drafts"],
        ], row["badge"])
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
            try self.insertThread(db, id: "t4", account: "a@x.com", unread: true, inbox: false,
                                  social: true)
            try self.insertThread(db, id: "t5", account: "a@x.com", unread: false, inbox: true,
                                  starred: true)
            try self.insertThread(db, id: "t6", account: "a@x.com", unread: false, inbox: false,
                                  drafts: true)
            // Other account: one inbox unread
            try self.insertThread(db, id: "t7", account: "b@x.com", unread: true, inbox: true)
        }

        let (all, badgeAll) = try q.read {
            try self.fetchSidebarCounts(db: $0, activeAccount: nil, badgeAccount: nil)
        }
        XCTAssertEqual(all["inbox"], 3)          // t1,t2,t7
        XCTAssertEqual(all["promotions"], 1)     // t3
        XCTAssertEqual(all["social"], 1)         // t4
        XCTAssertEqual(all["starred"], 1)        // t5
        XCTAssertEqual(all["drafts"], 1)         // t6
        XCTAssertEqual(badgeAll, 3)

        let (scoped, badgeScoped) = try q.read {
            try self.fetchSidebarCounts(db: $0, activeAccount: "a@x.com",
                                        badgeAccount: "b@x.com")
        }
        XCTAssertEqual(scoped["inbox"], 2)       // a only
        XCTAssertEqual(badgeScoped, 1)           // b only
    }

    // MARK: - VIP fromEmail prefer + fallback

    /// Mirrors MailStore.computeVIPThreadIds (Database.swift-level pure helper).
    private func computeVIPThreadIds(threads: [MailThread], activeVIP: Set<String>,
                                     db: Database) throws -> Set<String> {
        guard !activeVIP.isEmpty, !threads.isEmpty else { return [] }
        var hits = Set<String>()
        var fallbackIds: [String] = []
        for t in threads {
            if !t.fromEmail.isEmpty {
                if activeVIP.contains(t.fromEmail) { hits.insert(t.id) }
            } else {
                fallbackIds.append(t.id)
            }
        }
        guard !fallbackIds.isEmpty else { return hits }
        let placeholders = fallbackIds.map { _ in "?" }.joined(separator: ",")
        let rows = try Row.fetchAll(db, sql: """
            SELECT DISTINCT threadId, fromHeader FROM message
            WHERE threadId IN (\(placeholders))
            """, arguments: StatementArguments(fallbackIds))
        for row in rows {
            let header: String = row["fromHeader"]
            if activeVIP.contains(MessageParser.emailAddress(header).lowercased()) {
                hits.insert(row["threadId"])
            }
        }
        return hits
    }

    func testVIPPrefersFromEmailAndFallsBackToMessageScan() throws {
        let q = try makeDB()
        let account = "a@x.com"
        try q.write { db in
            try Account(id: account, displayName: "A", historyId: nil,
                        lastSyncAt: nil, senderName: "").insert(db)
            // Thread with denorm fromEmail filled.
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
}
