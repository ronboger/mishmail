import XCTest
import GRDB

/// Pure ranking + DB integration for typo-tolerant FTS fallback.
final class FuzzySearchTests: XCTestCase {

    // MARK: - Pure ranking

    func testCandidatesPicksLeviForLevis() {
        let hits = FuzzySearch.candidates(
            for: "levis", in: ["levi", "level", "list"], limit: 3)
        XCTAssertEqual(hits.first, "levi")
        XCTAssertFalse(hits.contains("level"),
                       "level is distance 2; levis is len 5 → max dist 1")
        XCTAssertFalse(hits.contains("list"))
    }

    func testDistanceTwoOnlyForLongTerms() {
        // "recieve"/"receive" is an adjacent transposition (distance 1);
        // length ≥ 6 allows up to 2, so this must match.
        let hits = FuzzySearch.candidates(
            for: "recieve", in: ["receive", "recipe", "recite"], limit: 3)
        XCTAssertEqual(hits.first, "receive")

        // Short term: distance 2 must not match.
        let short = FuzzySearch.candidates(
            for: "cat", in: ["cut", "cart", "dog"], limit: 5)
        // "cut" is distance 1 (substitute a→u) — allowed.
        XCTAssertTrue(short.contains("cut"))
        // "cart" is distance 1 (insert r) — allowed.
        // "dog" is distance 3 — not allowed.
        XCTAssertFalse(short.contains("dog"))
    }

    func testTermsUnderThreeCharsIgnored() {
        XCTAssertEqual(
            FuzzySearch.candidates(for: "ab", in: ["abc", "ab", "a"], limit: 3),
            [])
        XCTAssertEqual(
            FuzzySearch.candidates(for: "a", in: ["a", "ab", "abc"], limit: 3),
            [])
    }

    func testRankingPrefersCloserThenLongerPrefix() {
        // Both distance 1 from "apple": "apply" (prefix 3), "ample" (prefix 1).
        let hits = FuzzySearch.candidates(
            for: "apple", in: ["ample", "apply", "apples"], limit: 3)
        XCTAssertEqual(hits.first, "apples",
                       "distance 1 insert, longest shared prefix")
        if hits.count >= 2 {
            XCTAssertEqual(hits[1], "apply")
        }
    }

    func testOriginalTokenIncludedInExpandedGroup() throws {
        // When the original is itself in vocab, candidates returns it at dist 0;
        // expandedPattern always puts the original first in the OR-group even
        // if ranking ordered differently.
        let q = try makeDB()
        try q.write { db in
            try self.seed(db, gmailId: "t1", subject: "Levi's Jeans - 40% off",
                          date: Date())
        }
        try q.read { db in
            guard let pattern = try FuzzySearch.expandedPattern(db: db, text: "levis")
            else {
                XCTFail("expected expanded pattern for levis → levi")
                return
            }
            let raw = pattern.rawPattern
            XCTAssertTrue(raw.contains("levis") || raw.contains("\"levis\""),
                          "original token must appear in pattern: \(raw)")
            XCTAssertTrue(raw.contains("levi"),
                          "fuzzy candidate levi must appear: \(raw)")
        }
    }

    // MARK: - DB integration (ThreadTypeahead path)

    func testFuzzyFindsLevisTypo() throws {
        let q = try makeDB()
        try q.write { db in
            try self.seed(db, gmailId: "promo",
                          subject: "Levi's Jeans - 40% off", date: Date())
        }
        let hits = try q.read {
            try ThreadTypeahead.fetch(db: $0, query: "levis", limit: 5)
        }
        XCTAssertEqual(hits.map(\.gmailThreadId), ["promo"],
                       "levis must fuzzy-match Levi's via vocab")
    }

    func testExactLeviStillFinds() throws {
        let q = try makeDB()
        try q.write { db in
            try self.seed(db, gmailId: "promo",
                          subject: "Levi's Jeans - 40% off", date: Date())
        }
        let hits = try q.read {
            try ThreadTypeahead.fetch(db: $0, query: "levi", limit: 5)
        }
        XCTAssertEqual(hits.map(\.gmailThreadId), ["promo"])
    }

    func testGarbageFindsNothing() throws {
        let q = try makeDB()
        try q.write { db in
            try self.seed(db, gmailId: "promo",
                          subject: "Levi's Jeans - 40% off", date: Date())
        }
        let hits = try q.read {
            try ThreadTypeahead.fetch(db: $0, query: "zzqqxx", limit: 5)
        }
        XCTAssertTrue(hits.isEmpty)
    }

    func testStrictHitNotDilutedByFuzzy() throws {
        // When strict FTS has hits, fuzzy must not re-run. Both subjects match
        // "levi*" via prefix; results come from the strict path only.
        let q = try makeDB()
        try q.write { db in
            try self.seed(db, gmailId: "exact", subject: "levi denim",
                          date: Date().addingTimeInterval(-60))
            try self.seed(db, gmailId: "typoish", subject: "levis sale",
                          date: Date())
        }
        let hits = try q.read {
            try ThreadTypeahead.fetch(db: $0, query: "levi", limit: 5)
        }
        let ids = Set(hits.map(\.gmailThreadId))
        XCTAssertTrue(ids.contains("exact"))
        XCTAssertTrue(ids.contains("typoish"),
                      "strict levi* prefix matches both levi and levis tokens")
        XCTAssertEqual(hits.count, 2)
    }

    func testMultiTokenFuzzy() throws {
        let q = try makeDB()
        try q.write { db in
            try self.seed(db, gmailId: "pair", subject: "Levi's Jeans",
                          date: Date())
        }
        let hits = try q.read {
            try ThreadTypeahead.fetch(db: $0, query: "levis jeans", limit: 5)
        }
        XCTAssertEqual(hits.map(\.gmailThreadId), ["pair"])
    }

    // MARK: - Helpers (ThreadTypeaheadTests pattern)

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
}
