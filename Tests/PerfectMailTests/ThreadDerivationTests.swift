import XCTest

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
}
