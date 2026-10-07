import XCTest
import GRDB

/// `SearchThreadQuery` is the committed-search thread query that
/// `MailStore.reloadThreads` runs. These tests execute the production SQL
/// against a migrated in-memory database, one operator at a time.
final class SearchThreadQueryTests: XCTestCase {

    // MARK: - Fixtures

    static let account = "a@x.com"
    static let otherAccount = "b@y.com"

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            for id in [Self.account, Self.otherAccount] {
                try Account(id: id, displayName: "A", historyId: nil,
                            lastSyncAt: nil, senderName: "").insert(db)
            }
        }
        return q
    }

    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    /// One message of a seeded thread.
    struct Msg {
        var from = "Fred <fred@x.com>"
        var to = "me@x.com"
        var cc = ""
        var bcc = ""
        var date: Date = SearchThreadQueryTests.day(2026, 7, 10)
        var messageId: String?
        var attachments: [String] = []
    }

    /// Insert a thread and its messages. `lastDate` is the newest message.
    @discardableResult
    private func seed(_ db: Database, _ id: String,
                      account: String = SearchThreadQueryTests.account,
                      subject: String = "Hello",
                      fromDisplay: String = "Fred",
                      fromEmail: String = "fred@x.com",
                      labelIds: String = "INBOX",
                      userLabels: [String] = [],
                      isUnread: Bool = false,
                      hasAttachment: Bool = false,
                      inDrafts: Bool = false,
                      snoozeUntil: Date? = nil,
                      messages: [Msg] = [Msg()],
                      edit: (inout MailThread) -> Void = { _ in }) throws -> MailThread {
        let prefix = account == Self.account ? "a" : "b"
        let lastDate = messages.map(\.date).max() ?? Date()
        var t = MailThread(
            id: "\(prefix):\(id)", accountId: account, gmailThreadId: id,
            subject: subject, snippet: "sn", fromDisplay: fromDisplay,
            lastDate: lastDate, isUnread: isUnread, isStarred: false,
            inInbox: false, inTrash: false,
            labelIds: labelIds, snoozeUntil: snoozeUntil, participants: fromDisplay,
            messageCount: messages.count, hasAttachment: hasAttachment,
            reminderAt: nil)
        t.syncFlagsFromLabelIds()
        t.inTrash = t.labels.contains("TRASH")
        t.inDrafts = inDrafts
        t.fromEmail = fromEmail
        edit(&t)
        try t.insert(db)
        for (i, m) in messages.enumerated() {
            let mid = "\(t.id):m\(i)"
            try Message(
                id: mid, accountId: account, gmailId: "\(id)m\(i)",
                threadId: t.id, fromHeader: m.from, toHeader: m.to,
                ccHeader: m.cc, bccHeader: m.bcc, subject: subject, date: m.date,
                snippet: "sn", bodyText: "body", bodyHTML: nil,
                messageIdHeader: m.messageId ?? "<\(id)-\(i)@x>", referencesHeader: "",
                labelIds: labelIds, isUnread: isUnread,
                hasAttachment: !m.attachments.isEmpty).insert(db)
            for name in m.attachments {
                var row = AttachmentRow(
                    id: nil, messageId: mid, gmailAttachmentId: "att-\(name)",
                    filename: name, mimeType: "application/octet-stream", size: 10)
                try row.insert(db)
            }
        }
        for label in userLabels {
            try ThreadLabel(threadId: t.id, labelId: label).insert(db)
        }
        return t
    }

    private func ids(_ db: Database, _ search: String,
                     _ context: SearchThreadQuery.Context = .init(),
                     limit: Int = 500) throws -> [String] {
        try SearchThreadQuery.fetch(search: search, db: db, context: context,
                                    limit: limit).map(\.id)
    }

    private func label(_ name: String, _ gmailId: String,
                       account: String = SearchThreadQueryTests.account) -> LabelRow {
        LabelRow(id: "\(account):\(gmailId)", accountId: account,
                 gmailLabelId: gmailId, name: name, type: "user", color: nil)
    }

    // MARK: - Text and scope

    func testTextMatchesSubjectAndHidesTrashAndSpam() throws {
        let q = try makeDB()
        try q.write { db in
            try seed(db, "t1", subject: "Invoice from Acme")
            try seed(db, "t2", subject: "Invoice reminder", labelIds: "TRASH")
            try seed(db, "t3", subject: "Invoice offer", labelIds: "SPAM")
            try seed(db, "t4", subject: "Lunch plans")
        }
        try q.read { db in
            XCTAssertEqual(try ids(db, "invoice"), ["a:t1"])
            XCTAssertEqual(try ids(db, "invoice in:trash"), ["a:t2"])
            XCTAssertEqual(try ids(db, "invoice in:spam"), ["a:t3"])
            XCTAssertEqual(try ids(db, "invoice in:anywhere").sorted(),
                           ["a:t1", "a:t2", "a:t3"])
            XCTAssertEqual(try ids(db, "zzqqxx"), [])
        }
    }

    /// An operator the parser does not know stays plain text: the words go
    /// to full-text search, they are never dropped.
    func testUnknownOperatorIsPlainText() throws {
        let q = try makeDB()
        try q.write { db in
            try seed(db, "t1", subject: "larger 5M files")
            try seed(db, "t2", subject: "Lunch plans")
        }
        try q.read { db in
            XCTAssertEqual(try ids(db, "larger:5M"), ["a:t1"])
        }
    }

    func testAccountScope() throws {
        let q = try makeDB()
        try q.write { db in
            try seed(db, "t1", subject: "Invoice one")
            try seed(db, "t2", account: Self.otherAccount, subject: "Invoice two")
        }
        try q.read { db in
            XCTAssertEqual(try ids(db, "invoice").sorted(), ["a:t1", "b:t2"])
            XCTAssertEqual(try ids(db, "invoice", .init(accountId: Self.otherAccount)),
                           ["b:t2"])
        }
    }

    func testOrderIsNewestFirstWithIdTieBreakAndLimit() throws {
        let q = try makeDB()
        try q.write { db in
            try seed(db, "t1", subject: "Report", messages: [Msg(date: Self.day(2026, 7, 1))])
            try seed(db, "t2", subject: "Report", messages: [Msg(date: Self.day(2026, 7, 3))])
            try seed(db, "t3", subject: "Report", messages: [Msg(date: Self.day(2026, 7, 3))])
        }
        try q.read { db in
            XCTAssertEqual(try ids(db, "report"), ["a:t3", "a:t2", "a:t1"])
            XCTAssertEqual(try ids(db, "report", limit: 2), ["a:t3", "a:t2"])
        }
    }

    // MARK: - People and subject

    func testFromMatchesDisplayNameEmailAndOlderMessageHeader() throws {
        let q = try makeDB()
        try q.write { db in
            try seed(db, "t1", fromDisplay: "Alice Smith", fromEmail: "alice@corp.com",
                     messages: [Msg(from: "Alice Smith <alice@corp.com>")])
            // Newest sender is Bob; Carol wrote an older message.
            try seed(db, "t2", fromDisplay: "Bob", fromEmail: "bob@corp.com",
                     messages: [Msg(from: "Carol <carol@corp.com>", date: Self.day(2026, 7, 1)),
                                Msg(from: "Bob <bob@corp.com>", date: Self.day(2026, 7, 2))])
        }
        try q.read { db in
            XCTAssertEqual(try ids(db, "from:alice"), ["a:t1"])
            XCTAssertEqual(try ids(db, "from:\"alice smith\""), ["a:t1"])
            XCTAssertEqual(try ids(db, "from:alice@corp.com"), ["a:t1"])
            XCTAssertEqual(try ids(db, "from:carol@corp.com"), ["a:t2"])
            XCTAssertEqual(try ids(db, "from:nobody"), [])
        }
    }

    func testToMatchesToCcAndBcc() throws {
        let q = try makeDB()
        try q.write { db in
            try seed(db, "t1", messages: [Msg(to: "dan@corp.com")])
            try seed(db, "t2", messages: [Msg(cc: "Dan <dan@corp.com>")])
            try seed(db, "t3", messages: [Msg(bcc: "dan@corp.com")])
            try seed(db, "t4", messages: [Msg(to: "erin@corp.com")])
        }
        try q.read { db in
            XCTAssertEqual(try ids(db, "to:dan").sorted(), ["a:t1", "a:t2", "a:t3"])
        }
    }

    func testSubjectOperator() throws {
        let q = try makeDB()
        try q.write { db in
            try seed(db, "t1", subject: "Q3 numbers final")
            try seed(db, "t2", subject: "Lunch plans")
        }
        try q.read { db in
            XCTAssertEqual(try ids(db, "subject:\"q3 numbers\""), ["a:t1"])
            XCTAssertEqual(try ids(db, "subject:lunch"), ["a:t2"])
        }
    }

    // MARK: - State

    func testUnreadAndReadWithKeepIds() throws {
        let q = try makeDB()
        try q.write { db in
            try seed(db, "t1", isUnread: true)
            try seed(db, "t2", isUnread: false)
        }
        try q.read { db in
            XCTAssertEqual(try ids(db, "is:unread"), ["a:t1"])
            XCTAssertEqual(try ids(db, "is:read"), ["a:t2"])
            XCTAssertEqual(try ids(db, "is:unread", .init(keepIds: ["a:t2"])).sorted(),
                           ["a:t1", "a:t2"])
        }
    }

    func testStarredWithStarKeepIds() throws {
        let q = try makeDB()
        try q.write { db in
            try seed(db, "t1", labelIds: "INBOX STARRED")
            try seed(db, "t2")
        }
        try q.read { db in
            XCTAssertEqual(try ids(db, "is:starred"), ["a:t1"])
            XCTAssertEqual(try ids(db, "is:starred", .init(starKeepIds: ["a:t2"])).sorted(),
                           ["a:t1", "a:t2"])
        }
    }

    func testHasAttachment() throws {
        let q = try makeDB()
        try q.write { db in
            try seed(db, "t1", hasAttachment: true)
            try seed(db, "t2")
        }
        try q.read { db in
            XCTAssertEqual(try ids(db, "has:attachment"), ["a:t1"])
        }
    }

    // MARK: - Dates

    /// Single-message threads: the message date is the thread date.
    func testAfterAndBeforeOnSingleMessageThreads() throws {
        let q = try makeDB()
        try q.write { db in
            try seed(db, "june", messages: [Msg(date: Self.day(2026, 6, 20))])
            try seed(db, "july", messages: [Msg(date: Self.day(2026, 7, 10))])
            try seed(db, "aug", messages: [Msg(date: Self.day(2026, 8, 5))])
        }
        try q.read { db in
            XCTAssertEqual(try ids(db, "after:2026/07/01"), ["a:aug", "a:july"])
            XCTAssertEqual(try ids(db, "before:2026/07/01"), ["a:june"])
            XCTAssertEqual(try ids(db, "after:2026/07/01 before:2026/08/01"), ["a:july"])
            // The lower bound is inclusive, the upper bound exclusive.
            XCTAssertEqual(try ids(db, "after:2026/07/10 before:2026/07/11"), ["a:july"])
            XCTAssertEqual(try ids(db, "before:2026/07/10"), ["a:june"])
        }
    }

    // MARK: - Labels

    func testLabelNameResolvesToUserLabelIds() throws {
        let q = try makeDB()
        try q.write { db in
            try seed(db, "t1", userLabels: ["Label_7"])
            try seed(db, "t2", userLabels: ["Label_8"])
            try seed(db, "t3")
        }
        let context = SearchThreadQuery.Context(
            labels: [label("Work", "Label_7"), label("Receipts", "Label_8")])
        try q.read { db in
            XCTAssertEqual(try ids(db, "label:work", context), ["a:t1"])
            XCTAssertEqual(try ids(db, "label:RECEIPTS", context), ["a:t2"])
            // Both labels must be present.
            XCTAssertEqual(try ids(db, "label:work label:receipts", context), [])
        }
    }

    func testUnknownLabelNameFallsBackToSystemLabel() throws {
        let q = try makeDB()
        try q.write { db in
            try seed(db, "t1", labelIds: "INBOX STARRED")
            try seed(db, "t2", labelIds: "SENT")
            try seed(db, "t3", labelIds: "INBOX IMPORTANT")
        }
        try q.read { db in
            XCTAssertEqual(try ids(db, "label:starred"), ["a:t1"])
            XCTAssertEqual(try ids(db, "label:starred", .init(starKeepIds: ["a:t2"])).sorted(),
                           ["a:t1", "a:t2"])
            XCTAssertEqual(try ids(db, "label:sent"), ["a:t2"])
            XCTAssertEqual(try ids(db, "label:important"), ["a:t3"])
            XCTAssertEqual(try ids(db, "label:nosuchlabel"), [])
        }
    }

    // MARK: - Combination

    func testOperatorsCombineWithText() throws {
        let q = try makeDB()
        try q.write { db in
            try seed(db, "t1", subject: "Flight to SFO", fromDisplay: "Carol",
                     isUnread: true, hasAttachment: true)
            try seed(db, "t2", subject: "Flight to JFK", fromDisplay: "Carol")
            try seed(db, "t3", subject: "Flight to SFO", fromDisplay: "Dave",
                     isUnread: true, hasAttachment: true)
        }
        try q.read { db in
            XCTAssertEqual(try ids(db, "from:carol has:attachment is:unread flight sfo"),
                           ["a:t1"])
        }
    }
}
