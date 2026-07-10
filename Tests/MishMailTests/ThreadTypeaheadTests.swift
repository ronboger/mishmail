import XCTest
import GRDB

/// Live `/` typeahead SQL — recency under a tight candidate cap, 1-char skip.
final class ThreadTypeaheadTests: XCTestCase {

    private let account = "a@x.com"

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: account, displayName: "A", historyId: nil,
                        lastSyncAt: nil, senderName: "").insert(db)
        }
        return q
    }

    /// Seed a thread + message. `rowid` order follows insert order; `date`
    /// is independent so we can prove ORDER BY MAX(date) beats rowid bias.
    private func seed(_ db: Database, gmailId: String, subject: String,
                      date: Date, trash: Bool = false) throws {
        let threadId = "\(account):\(gmailId)"
        let labels = trash ? "TRASH" : "INBOX"
        var t = MailThread(
            id: threadId, accountId: account, gmailThreadId: gmailId,
            subject: subject, snippet: "sn", fromDisplay: "F",
            lastDate: date, isUnread: false, isStarred: false,
            inInbox: !trash, inTrash: trash,
            labelIds: labels, snoozeUntil: nil, participants: "F",
            messageCount: 1, hasAttachment: false, reminderAt: nil)
        t.syncFlagsFromLabelIds()
        try t.insert(db)
        try Message(
            id: "\(threadId):m1", accountId: account, gmailId: "\(gmailId)m",
            threadId: threadId, fromHeader: "F <f@x.com>", toHeader: "me@x.com",
            ccHeader: "", subject: subject, date: date,
            snippet: "sn", bodyText: "body", bodyHTML: nil,
            messageIdHeader: "<\(gmailId)@x>", referencesHeader: "",
            labelIds: labels, isUnread: false, hasAttachment: false).insert(db)
    }

    func testSkipsQueriesShorterThanMinimum() throws {
        let q = try makeDB()
        try q.write { db in
            try self.seed(db, gmailId: "t1", subject: "Invoice from Acme",
                          date: Date())
        }
        let hits = try q.read {
            try ThreadTypeahead.fetch(db: $0, query: "I", limit: 5)
        }
        XCTAssertTrue(hits.isEmpty, "1-char must not run FTS")
    }

    func testPrefersNewestWhenOlderRowsComeFirst() throws {
        let q = try makeDB()
        let cal = Calendar(identifier: .gregorian)
        // Insert many OLD matching threads first (low rowids), then one NEW
        // match. Without ORDER BY newest in the candidate subquery, a tight
        // cap would drop the new thread.
        let oldBase = cal.date(from: DateComponents(year: 2020, month: 1, day: 1))!
        try q.write { db in
            // More than candidateCap(5)=80 so the new row is outside a
            // rowid-first window if ORDER BY is missing.
            for i in 0..<85 {
                let day = cal.date(byAdding: .day, value: i, to: oldBase)!
                try self.seed(db, gmailId: "old\(i)", subject: "Invoice \(i)",
                              date: day)
            }
            let newest = cal.date(from: DateComponents(year: 2026, month: 6, day: 1))!
            try self.seed(db, gmailId: "new", subject: "Invoice urgent",
                          date: newest)
        }

        let hits = try q.read {
            try ThreadTypeahead.fetch(db: $0, query: "Invoice", limit: 5)
        }
        XCTAssertFalse(hits.isEmpty)
        XCTAssertEqual(hits.first?.gmailThreadId, "new",
                       "newest matching thread must head the typeahead list")
        XCTAssertTrue(hits.allSatisfy { $0.subject.localizedCaseInsensitiveContains("Invoice") })
    }

    func testExcludesTrash() throws {
        let q = try makeDB()
        try q.write { db in
            try self.seed(db, gmailId: "live", subject: "Zebra report",
                          date: Date())
            try self.seed(db, gmailId: "gone", subject: "Zebra trash",
                          date: Date().addingTimeInterval(10), trash: true)
        }
        let hits = try q.read {
            try ThreadTypeahead.fetch(db: $0, query: "Zebra", limit: 5)
        }
        XCTAssertEqual(hits.map(\.gmailThreadId), ["live"])
    }
}
