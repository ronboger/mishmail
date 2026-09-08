import XCTest
import GRDB

/// `mailto:` From default: the mailbox that most recently corresponded with
/// the recipient, found through `message_fts`, never through a draft.
final class RecipientMailboxTests: XCTestCase {

    private let work = "work@x.com"
    private let personal = "me@gmail.com"

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            for id in [work, personal] {
                try Account(id: id, displayName: id, historyId: nil,
                            lastSyncAt: nil, senderName: "").insert(db)
            }
        }
        return q
    }

    /// One thread + one message in `account`. Insert order is deliberately
    /// unrelated to `date` so rowid order cannot stand in for recency.
    private func seed(_ db: Database, account: String, gmailId: String,
                      from: String, to: String, cc: String = "",
                      date: Date, labels: String = "INBOX") throws {
        let threadId = "\(account):\(gmailId)"
        var t = MailThread(
            id: threadId, accountId: account, gmailThreadId: gmailId,
            subject: "s", snippet: "sn", fromDisplay: "F",
            lastDate: date, isUnread: false, isStarred: false,
            inInbox: true, inTrash: false,
            labelIds: labels, snoozeUntil: nil, participants: "F",
            messageCount: 1, hasAttachment: false, reminderAt: nil)
        t.syncFlagsFromLabelIds()
        try t.insert(db)
        try Message(
            id: "\(threadId):m1", accountId: account, gmailId: "\(gmailId)m",
            threadId: threadId, fromHeader: from, toHeader: to,
            ccHeader: cc, subject: "s", date: date,
            snippet: "sn", bodyText: "body", bodyHTML: nil,
            messageIdHeader: "<\(gmailId)@x>", referencesHeader: "",
            labelIds: labels, isUnread: false, hasAttachment: false).insert(db)
    }

    func testPhraseTokenizesLikeUnicode61() {
        XCTAssertEqual(RecipientMailbox.phrase(for: "Dana.Okafor@BrightLoop.io"),
                       "\"dana okafor brightloop io\"")
        XCTAssertNil(RecipientMailbox.phrase(for: "@.."))
        XCTAssertEqual(
            RecipientMailbox.matchExpression(for: ["a@b.c", "d@e.f"]),
            "{fromHeader toHeader ccHeader} : (\"a b c\" OR \"d e f\")")
        XCTAssertNil(RecipientMailbox.matchExpression(for: []))
    }

    func testPicksMailboxOfNewestMessageNotNewestRow() throws {
        let q = try makeDB()
        let now = Date()
        try q.write { db in
            // Inserted first (lowest rowid) but newest by date: Gmail's
            // backfill order, where rowid ascends as date descends.
            try seed(db, account: personal, gmailId: "p1",
                     from: "Dana <dana@brightloop.io>", to: "me@gmail.com",
                     date: now)
            try seed(db, account: work, gmailId: "w1",
                     from: "Dana <dana@brightloop.io>", to: "work@x.com",
                     date: now.addingTimeInterval(-86_400 * 30))
        }
        let picked = try q.read { db in
            try RecipientMailbox.mostRecentMailbox(db: db, addresses: ["dana@brightloop.io"])
        }
        XCTAssertEqual(picked, personal)
    }

    func testOutboundMailCountsAndCaseIsIgnored() throws {
        let q = try makeDB()
        let now = Date()
        try q.write { db in
            try seed(db, account: work, gmailId: "w1",
                     from: "Me <work@x.com>", to: "Dana <Dana@BrightLoop.io>",
                     date: now, labels: "SENT")
        }
        let picked = try q.read { db in
            try RecipientMailbox.mostRecentMailbox(db: db, addresses: ["dana@brightloop.io"])
        }
        XCTAssertEqual(picked, work)
    }

    func testDraftsAreNotEvidence() throws {
        let q = try makeDB()
        let now = Date()
        try q.write { db in
            // A wrong first guess saved to Drafts in the personal mailbox…
            try seed(db, account: personal, gmailId: "d1",
                     from: "me@gmail.com", to: "dana@brightloop.io",
                     date: now, labels: "DRAFT")
            // …must lose to older real correspondence in the work mailbox.
            try seed(db, account: work, gmailId: "w1",
                     from: "Dana <dana@brightloop.io>", to: "work@x.com",
                     date: now.addingTimeInterval(-3600))
        }
        let picked = try q.read { db in
            try RecipientMailbox.mostRecentMailbox(db: db, addresses: ["dana@brightloop.io"])
        }
        XCTAssertEqual(picked, work)
    }

    func testTokenCollisionOnDisplayNameDoesNotMatch() throws {
        let q = try makeDB()
        try q.write { db in
            // Same tokens in the display name, different address.
            try seed(db, account: personal, gmailId: "p1",
                     from: "\"dana brightloop io\" <someone@else.org>",
                     to: "me@gmail.com", date: Date())
        }
        let picked = try q.read { db in
            try RecipientMailbox.mostRecentMailbox(db: db, addresses: ["dana@brightloop.io"])
        }
        XCTAssertNil(picked)
    }

    func testUnknownRecipientYieldsNil() throws {
        let q = try makeDB()
        try q.write { db in
            try seed(db, account: work, gmailId: "w1",
                     from: "x@y.z", to: "work@x.com", date: Date())
        }
        let picked = try q.read { db in
            try RecipientMailbox.mostRecentMailbox(db: db, addresses: ["nobody@nowhere.test"])
        }
        XCTAssertNil(picked)
    }

    func testAnyOfSeveralRecipientsCounts() throws {
        let q = try makeDB()
        try q.write { db in
            try seed(db, account: work, gmailId: "w1",
                     from: "Bob <bob@corp.com>", to: "work@x.com", date: Date())
        }
        let picked = try q.read { db in
            try RecipientMailbox.mostRecentMailbox(
                db: db, addresses: ["alice@corp.com", "bob@corp.com"])
        }
        XCTAssertEqual(picked, work)
    }
}
