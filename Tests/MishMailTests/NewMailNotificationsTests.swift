import XCTest
import GRDB

final class NewMailNotificationsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private let nineAM = Date(timeIntervalSince1970: 1_000)
    private let tenAM = Date(timeIntervalSince1970: 2_000)

    private func candidate(
        _ id: String, from: String = "alice@example.com", allFrom: String? = nil,
        inbound: Date?, isUnread: Bool = true, inInbox: Bool = true,
        inTrash: Bool = false, inSpam: Bool = false, inPromotions: Bool = false,
        inSocial: Bool = false, snoozeUntil: Date? = nil
    ) -> NewMailNotifications.Candidate {
        .init(id: id, fromEmail: from, allFromEmails: allFrom ?? from,
              lastInboundDate: inbound, isUnread: isUnread, inInbox: inInbox,
              inTrash: inTrash, inSpam: inSpam, inPromotions: inPromotions,
              inSocial: inSocial, snoozeUntil: snoozeUntil)
    }

    private func seeded(_ current: [NewMailNotifications.Candidate] = []) -> NewMailNotifications {
        var state = NewMailNotifications()
        state.seed(current)
        return state
    }

    private func fresh(_ state: inout NewMailNotifications,
                       _ current: [NewMailNotifications.Candidate],
                       demoMode: Bool = false,
                       blocked: Set<String> = []) -> [String] {
        state.fresh(current: current, now: now, demoMode: demoMode) { blocked.contains($0) }
    }

    // MARK: Baseline

    func testSeededBaselineIsSilent() {
        var state = seeded([candidate("a:t1", inbound: nineAM)])
        XCTAssertTrue(state.isSeeded)
        XCTAssertEqual(fresh(&state, [candidate("a:t1", inbound: nineAM)]), [])
    }

    /// A sync can beat the deferred launch seed. That first pass is the
    /// baseline: every cached unread thread would otherwise notify at once.
    func testFirstPassWithoutSeedAdoptsTheBaselineAndIsSilent() {
        var state = NewMailNotifications()
        XCTAssertFalse(state.isSeeded)
        XCTAssertEqual(fresh(&state, [candidate("a:t1", inbound: nineAM)]), [])
        XCTAssertTrue(state.isSeeded)
        XCTAssertEqual(fresh(&state, [candidate("a:t1", inbound: nineAM)]), [])
    }

    // MARK: New mail

    func testNewThreadNotifiesOnce() {
        var state = seeded()
        let mail = [candidate("a:t1", inbound: nineAM)]
        XCTAssertEqual(fresh(&state, mail), ["a:t1"])
        XCTAssertEqual(fresh(&state, mail), [], "same thread, same inbound date")
    }

    /// The defect: the old id set only grew, so a thread that had notified
    /// once (or was unread at launch) stayed silent for the whole session.
    func testLaterReplyInAnAlreadyNotifiedThreadNotifiesAgain() {
        var state = seeded()
        XCTAssertEqual(fresh(&state, [candidate("a:t1", inbound: nineAM)]), ["a:t1"])
        // Read in between: the thread leaves the unread set.
        XCTAssertEqual(fresh(&state, []), [])
        XCTAssertEqual(fresh(&state, [candidate("a:t1", inbound: tenAM)]), ["a:t1"])
        XCTAssertEqual(fresh(&state, [candidate("a:t1", inbound: tenAM)]), [])
    }

    func testLaterReplyInAThreadUnreadAtLaunchNotifies() {
        var state = seeded([candidate("a:t1", inbound: nineAM)])
        XCTAssertEqual(fresh(&state, [candidate("a:t1", inbound: tenAM)]), ["a:t1"])
    }

    /// `u` on a thread that already notified puts it back in the unread set
    /// with the same inbound date. That is not new mail.
    func testMarkUnreadOfAKnownThreadDoesNotNotify() {
        var state = seeded()
        XCTAssertEqual(fresh(&state, [candidate("a:t1", inbound: nineAM)]), ["a:t1"])
        XCTAssertEqual(fresh(&state, []), [])
        XCTAssertEqual(fresh(&state, [candidate("a:t1", inbound: nineAM)]), [])
    }

    func testAnOlderInboundDateDoesNotNotify() {
        var state = seeded([candidate("a:t1", inbound: tenAM)])
        XCTAssertEqual(fresh(&state, [candidate("a:t1", inbound: nineAM)]), [])
        XCTAssertEqual(fresh(&state, [candidate("a:t1", inbound: tenAM)]), [],
                       "the known date never moves backwards")
    }

    func testResultKeepsTheCallerOrder() {
        var state = seeded()
        let ids = fresh(&state, [candidate("a:t2", inbound: tenAM),
                                 candidate("a:t1", inbound: nineAM)])
        XCTAssertEqual(ids, ["a:t2", "a:t1"])
    }

    // MARK: Guards

    /// Own sent mail: a pure-outbound thread has no inbound date, and an own
    /// reply in a known thread leaves the inbound date where it was.
    func testOwnSentMailDoesNotNotify() {
        var state = seeded([candidate("a:t1", inbound: nineAM)])
        XCTAssertEqual(fresh(&state, [candidate("a:sent", inbound: nil)]), [])
        XCTAssertEqual(fresh(&state, [candidate("a:t1", inbound: nineAM)]), [])
    }

    func testBlockedSenderDoesNotNotify() {
        var state = seeded()
        let mail = [candidate("a:t1", from: "spam@example.com", inbound: nineAM)]
        XCTAssertEqual(fresh(&state, mail, blocked: ["spam@example.com"]), [])
        // Unblocking later must not surface the old mail as new.
        XCTAssertEqual(fresh(&state, mail), [])
    }

    /// Same any-message match as the blocklist sweep: the newest message can
    /// be from someone else in a thread a blocked sender also wrote in.
    func testBlockedSenderAnywhereInTheThreadDoesNotNotify() {
        var state = seeded()
        let mail = [candidate("a:t1", from: "alice@example.com",
                              allFrom: "alice@example.com spam@example.com",
                              inbound: nineAM)]
        XCTAssertEqual(fresh(&state, mail, blocked: ["spam@example.com"]), [])
    }

    func testArchivedReadTrashedAndSpamDoNotNotify() {
        var state = seeded()
        XCTAssertEqual(fresh(&state, [
            candidate("a:archived", inbound: nineAM, inInbox: false),
            candidate("a:read", inbound: nineAM, isUnread: false),
            candidate("a:trash", inbound: nineAM, inTrash: true),
            candidate("a:spam", inbound: nineAM, inSpam: true),
        ]), [])
    }

    func testPromotionsAndSocialDoNotNotify() {
        var state = seeded()
        XCTAssertEqual(fresh(&state, [
            candidate("a:promo", inbound: nineAM, inPromotions: true),
            candidate("a:social", inbound: nineAM, inSocial: true),
        ]), [])
    }

    func testSnoozedThreadDoesNotNotifyUntilItWakes() {
        var state = seeded()
        let asleep = candidate("a:t1", inbound: nineAM,
                               snoozeUntil: now.addingTimeInterval(60))
        XCTAssertEqual(fresh(&state, [asleep]), [])
        let awake = candidate("a:t1", inbound: nineAM,
                              snoozeUntil: now.addingTimeInterval(-60))
        XCTAssertEqual(fresh(&state, [awake]), ["a:t1"])
    }

    func testDemoModeNeverNotifies() {
        var state = seeded()
        let mail = [candidate("a:t1", inbound: nineAM)]
        XCTAssertEqual(fresh(&state, mail, demoMode: true), [])
        // Leaving the demo must not replay what arrived during it.
        XCTAssertEqual(fresh(&state, mail), [])
    }

    // MARK: Read

    /// The store reads through `try?`: a projection that failed to decode
    /// would silently end every notification. Runs against the real schema.
    func testUnreadInboxCandidatesDecodeFromTheRealSchema() throws {
        let account = "ron@x.com"
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        let inboundDate = Date(timeIntervalSince1970: 5_000)
        try q.write { db in
            try Account(id: account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            // t1 unread inbox, t2 read inbox, t3 unread archived, t4 own send.
            let rows: [(thread: String, from: String, labels: String)] = [
                ("t1", "Alice <Alice@B.com>", "INBOX UNREAD"),
                ("t2", "a@b.com", "INBOX"),
                ("t3", "a@b.com", "UNREAD"),
                ("t4", account, "SENT"),
            ]
            for row in rows {
                try Message(id: "\(account):m-\(row.thread)", accountId: account,
                            gmailId: "m-\(row.thread)", threadId: "\(account):\(row.thread)",
                            fromHeader: row.from, toHeader: account, ccHeader: "",
                            bccHeader: "", subject: "Hello", date: inboundDate,
                            snippet: "", bodyText: "", bodyHTML: nil,
                            messageIdHeader: "", referencesHeader: "",
                            labelIds: row.labels, isUnread: row.labels.contains("UNREAD"),
                            hasAttachment: false).insert(db)
            }
            try SyncEngine.deriveThreads(
                db, for: Set(rows.map { "\(account):\($0.thread)" }), accountId: account)
        }
        let candidates = try q.read {
            try NewMailNotifications.unreadInboxCandidates($0, now: now)
        }
        XCTAssertEqual(candidates.map(\.id), ["\(account):t1"])
        let c = try XCTUnwrap(candidates.first)
        XCTAssertEqual(c.fromEmail, "alice@b.com")
        XCTAssertEqual(c.allFromEmails, "alice@b.com")
        XCTAssertEqual(c.lastInboundDate, inboundDate)
        XCTAssertNil(c.snoozeUntil)
        XCTAssertTrue(NewMailNotifications.isEligible(c, now: now))

        var state = seeded()
        XCTAssertEqual(fresh(&state, candidates), ["\(account):t1"])
    }

    func testSnoozedRowIsNotACandidate() throws {
        let account = "ron@x.com"
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            try Message(id: "\(account):m1", accountId: account, gmailId: "m1",
                        threadId: "\(account):t1", fromHeader: "a@b.com",
                        toHeader: account, ccHeader: "", bccHeader: "",
                        subject: "Hello", date: Date(timeIntervalSince1970: 5_000),
                        snippet: "", bodyText: "", bodyHTML: nil,
                        messageIdHeader: "", referencesHeader: "",
                        labelIds: "INBOX UNREAD", isUnread: true,
                        hasAttachment: false).insert(db)
            try SyncEngine.deriveThreads(db, for: ["\(account):t1"], accountId: account)
            try db.execute(sql: "UPDATE thread SET snoozeUntil = ?",
                           arguments: [self.now.addingTimeInterval(60)])
        }
        XCTAssertEqual(try q.read {
            try NewMailNotifications.unreadInboxCandidates($0, now: self.now).count
        }, 0)
        XCTAssertEqual(try q.read {
            try NewMailNotifications.unreadInboxCandidates(
                $0, now: self.now.addingTimeInterval(120)).count
        }, 1)
    }
}
