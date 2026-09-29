import XCTest
import GRDB

/// `SearchFTS.filter` keeps the full-text match inside SQL. The old path
/// bound every matching thread id as its own `?`, which fails past
/// SQLITE_MAX_VARIABLE_NUMBER — and the reload's `try?` turned that into an
/// empty list. These tests pin the semantics (strict prefix first, fuzzy
/// only when strict is empty, no match → no rows) and the bind-count fix.
final class SearchFTSTests: XCTestCase {

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: "a@x.com", displayName: "A", historyId: nil,
                        lastSyncAt: nil, senderName: "").insert(db)
        }
        return q
    }

    private func seed(_ db: Database, id: String, subject: String,
                      date: Date = Date()) throws {
        var t = MailThread(
            id: "a:\(id)", accountId: "a@x.com", gmailThreadId: id,
            subject: subject, snippet: "sn", fromDisplay: "F",
            lastDate: date, isUnread: false, isStarred: false,
            inInbox: true, inTrash: false,
            labelIds: "INBOX", snoozeUntil: nil, participants: "F",
            messageCount: 1, hasAttachment: false, reminderAt: nil)
        t.syncFlagsFromLabelIds()
        try t.insert(db)
        try Message(
            id: "a:\(id):m1", accountId: "a@x.com", gmailId: "\(id)m1",
            threadId: t.id, fromHeader: "F <f@x.com>", toHeader: "me@x.com",
            ccHeader: "", subject: subject, date: date,
            snippet: "sn", bodyText: "body", bodyHTML: nil,
            messageIdHeader: "<\(id)@x>", referencesHeader: "",
            labelIds: "INBOX", isUnread: false, hasAttachment: false).insert(db)
    }

    private func search(_ db: Database, _ text: String) throws -> [String] {
        try SearchFTS.filter(MailThread.all(), db: db, text: text)
            .order(Column("lastDate").desc, Column("id").desc)
            .fetchAll(db).map(\.id)
    }

    func testStrictPrefixMatch() throws {
        let q = try makeDB()
        try q.write { db in
            try seed(db, id: "t1", subject: "Invoice from Acme")
            try seed(db, id: "t2", subject: "Lunch plans")
        }
        try q.read { db in
            XCTAssertEqual(try search(db, "invo"), ["a:t1"])
            XCTAssertEqual(try search(db, "acme invoice"), ["a:t1"])
        }
    }

    /// A thread with several matching messages appears once (IN, not JOIN).
    func testThreadWithSeveralMatchesAppearsOnce() throws {
        let q = try makeDB()
        try q.write { db in
            try seed(db, id: "t1", subject: "Invoice one")
            try Message(
                id: "a:t1:m2", accountId: "a@x.com", gmailId: "t1m2",
                threadId: "a:t1", fromHeader: "F <f@x.com>", toHeader: "me@x.com",
                ccHeader: "", subject: "Re: Invoice one", date: Date(),
                snippet: "sn", bodyText: "body", bodyHTML: nil,
                messageIdHeader: "<t1m2@x>", referencesHeader: "",
                labelIds: "INBOX", isUnread: false, hasAttachment: false).insert(db)
        }
        try q.read { db in
            XCTAssertEqual(try search(db, "invoice"), ["a:t1"])
        }
    }

    /// Fuzzy expansion runs only when the strict pattern has no hit.
    func testFuzzyFallbackOnlyWhenStrictIsEmpty() throws {
        let q = try makeDB()
        try q.write { db in
            try seed(db, id: "t1", subject: "Invoice from Acme")
        }
        try q.read { db in
            let strict = try search(db, "invoice")
            XCTAssertEqual(strict, ["a:t1"])
            let fuzzy = try FuzzySearch.expandedPattern(db: db, text: "invoise")
            if fuzzy != nil {
                XCTAssertEqual(try search(db, "invoise"), ["a:t1"],
                               "typo must fall back to the fuzzy pattern")
            }
            XCTAssertEqual(try search(db, "zzqqxx"), [],
                           "no strict and no fuzzy match → no rows")
        }
    }

    /// The old `id IN (?, ?, …)` failed once matches exceeded the bind limit.
    /// Lower the limit on this connection so a handful of rows proves the
    /// match no longer binds one variable per thread.
    func testMatchCountAboveBindLimit() throws {
        let q = try makeDB()
        try q.write { db in
            for i in 0..<20 {
                try seed(db, id: "t\(i)", subject: "Report \(i)",
                         date: Date(timeIntervalSince1970: TimeInterval(1_000 + i)))
            }
        }
        try q.read { db in
            sqlite3_limit(db.sqliteConnection, SQLITE_LIMIT_VARIABLE_NUMBER, 5)
            let ids = try search(db, "report")
            XCTAssertEqual(ids.count, 20)
            XCTAssertEqual(ids.first, "a:t19")
        }
    }
}
