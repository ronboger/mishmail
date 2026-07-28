import XCTest
import GRDB

/// Regression: unstarring a thread that was only visible because of star
/// pin-through (category hide, Starred mailbox, is:starred search, starredOnly
/// saved views) used to drop the row immediately. Users often still want to
/// work the thread — keepIds hold it until the view/filter changes.
///
/// Mirrors production SQL from `CategoryHide`, `.starred` baseQuery, and the
/// committed-search `is:starred` branch (hostless test target has no AppKit
/// MailStore). Update these copies if those paths change.
final class StarUnstarStickinessTests: XCTestCase {

    // MARK: - Fixtures

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: "a@x.com", displayName: "A", historyId: nil,
                        lastSyncAt: nil, senderName: "").insert(db)
        }
        return q
    }

    private func makeThread(
        id: String,
        subject: String,
        isStarred: Bool,
        inPromotions: Bool = false,
        inInbox: Bool = true,
        inTrash: Bool = false,
        labelIds: String = "INBOX"
    ) -> MailThread {
        var t = MailThread(
            id: "a:\(id)", accountId: "a@x.com", gmailThreadId: id,
            subject: subject, snippet: "sn", fromDisplay: "F",
            lastDate: Date(), isUnread: false, isStarred: isStarred,
            inInbox: inInbox, inTrash: inTrash,
            labelIds: labelIds, snoozeUntil: nil, participants: "F",
            messageCount: 1, hasAttachment: false, reminderAt: nil)
        t.inPromotions = inPromotions
        if isStarred {
            let labels = Set(t.labelIds.split(separator: " ").map(String.init))
            if !labels.contains("STARRED") {
                t.labelIds = (t.labelIds + " STARRED").trimmingCharacters(in: .whitespaces)
            }
        } else {
            t.labelIds = t.labelIds
                .split(separator: " ")
                .map(String.init)
                .filter { $0 != "STARRED" }
                .joined(separator: " ")
        }
        return t
    }

    /// Mirrors `.starred` baseQuery with starKeepIds stickiness.
    private func starredListSubjects(
        _ db: Database, keepIds: [String] = []
    ) throws -> [String] {
        let q = MailThread.all()
            .filter((Column("isStarred") == true || keepIds.contains(Column("id")))
                    && Column("inTrash") == false)
        return try q.order(Column("subject").asc).fetchAll(db).map(\.subject)
    }

    /// Mirrors committed-search is:starred + standard location.
    private func searchStarredSubjects(
        _ db: Database, keepIds: [String] = []
    ) throws -> [String] {
        let q = MailThread.all()
            .filter(Column("isStarred") == true || keepIds.contains(Column("id")))
            .filter(Column("inTrash") == false && Column("inSpam") == false)
        return try q.order(Column("subject").asc).fetchAll(db).map(\.subject)
    }

    /// Mirrors saved-view starredOnly filter with starKeepIds.
    private func starredOnlySubjects(
        _ db: Database, keepIds: [String] = []
    ) throws -> [String] {
        let q = MailThread.all()
            .filter(Column("inTrash") == false)
            .filter(Column("isStarred") == true || keepIds.contains(Column("id")))
        return try q.order(Column("subject").asc).fetchAll(db).map(\.subject)
    }

    // MARK: - Starred mailbox

    func testUnstarInStarredMailboxStaysWithKeepIds() throws {
        let db = try makeDB()
        try db.write { db in
            try makeThread(id: "s1", subject: "Just unstarred",
                           isStarred: false).insert(db)
            try makeThread(id: "s2", subject: "Still starred",
                           isStarred: true).insert(db)
            try makeThread(id: "s3", subject: "Never starred",
                           isStarred: false).insert(db)
        }

        let without = try db.read { try starredListSubjects($0) }
        XCTAssertEqual(without, ["Still starred"])

        let withKeep = try db.read {
            try starredListSubjects($0, keepIds: ["a:s1"])
        }
        XCTAssertEqual(withKeep, ["Just unstarred", "Still starred"],
                       "just-unstarred row stays under Starred via keepIds")
    }

    func testStarredMailboxKeepIdsDoNotShowTrash() throws {
        let db = try makeDB()
        try db.write { db in
            try makeThread(id: "t1", subject: "Trashed unstarred",
                           isStarred: false, inInbox: false, inTrash: true,
                           labelIds: "TRASH").insert(db)
            try makeThread(id: "s1", subject: "Active unstarred keep",
                           isStarred: false).insert(db)
        }

        let got = try db.read {
            try starredListSubjects($0, keepIds: ["a:t1", "a:s1"])
        }
        XCTAssertEqual(got, ["Active unstarred keep"])
    }

    // MARK: - is:starred search

    func testIsStarredSearchUnstarStickiness() throws {
        let db = try makeDB()
        try db.write { db in
            try makeThread(id: "s1", subject: "Just unstarred",
                           isStarred: false).insert(db)
            try makeThread(id: "s2", subject: "Still starred",
                           isStarred: true).insert(db)
        }

        let without = try db.read { try searchStarredSubjects($0) }
        XCTAssertEqual(without, ["Still starred"])

        let withKeep = try db.read {
            try searchStarredSubjects($0, keepIds: ["a:s1"])
        }
        XCTAssertEqual(withKeep, ["Just unstarred", "Still starred"])
    }

    // MARK: - starredOnly saved view

    func testStarredOnlySavedViewUnstarStickiness() throws {
        let db = try makeDB()
        try db.write { db in
            try makeThread(id: "s1", subject: "Just unstarred",
                           isStarred: false).insert(db)
            try makeThread(id: "s2", subject: "Still starred",
                           isStarred: true).insert(db)
        }

        let without = try db.read { try starredOnlySubjects($0) }
        XCTAssertEqual(without, ["Still starred"])

        let withKeep = try db.read {
            try starredOnlySubjects($0, keepIds: ["a:s1"])
        }
        XCTAssertEqual(withKeep, ["Just unstarred", "Still starred"])
    }

    // MARK: - Category hide (production CategoryHide)

    func testCategoryHideUnstarThenKeepIdsRoundTrip() throws {
        // Simulate: starred promo visible under hide → unstar + keep → still listed.
        let db = try makeDB()
        try db.write { db in
            try makeThread(id: "p1", subject: "Promo",
                           isStarred: true, inPromotions: true,
                           labelIds: "INBOX CATEGORY_PROMOTIONS STARRED").insert(db)
        }

        let hide: Set<String> = ["CATEGORY_PROMOTIONS"]
        let starred = try db.read {
            try CategoryHide.apply(MailThread.all(), hide: hide)
                .fetchAll($0).map(\.subject)
        }
        XCTAssertEqual(starred, ["Promo"])

        // Unstar in DB (what mutate does).
        try db.write { db in
            var t = try MailThread.fetchOne(db, key: "a:p1")!
            t.isStarred = false
            t.labelIds = "INBOX CATEGORY_PROMOTIONS"
            try t.update(db)
        }

        let dropped = try db.read {
            try CategoryHide.apply(MailThread.all(), hide: hide)
                .fetchAll($0).map(\.subject)
        }
        XCTAssertEqual(dropped, [], "without keepIds the unstarred promo vanishes")

        let sticky = try db.read {
            try CategoryHide.apply(MailThread.all(), hide: hide,
                                   keepIds: ["a:p1"])
                .fetchAll($0).map(\.subject)
        }
        XCTAssertEqual(sticky, ["Promo"],
                       "with keepIds the row stays for continued work")
    }

    // MARK: - Gate (when pin should arm)

    /// Mirrors `MailStore.starStateFilterActive` without AppKit.
    private func starFilterActive(
        hide: Set<String> = [],
        labelId: String? = nil,
        viewIsStarred: Bool = false,
        viewLabelIsStarred: Bool = false,
        savedStarredOnly: Bool = false,
        savedExcludePromotionsLegacy: Bool = false,
        search: String = ""
    ) -> Bool {
        if !hide.isEmpty { return true }
        if labelId == "STARRED" { return true }
        if viewIsStarred { return true }
        if viewLabelIsStarred { return true }
        if savedStarredOnly || savedExcludePromotionsLegacy { return true }
        let s = search.trimmingCharacters(in: .whitespaces)
        if !s.isEmpty {
            let parsed = SearchQuery.parse(s)
            if parsed.starred { return true }
            if parsed.labels.contains(where: {
                $0.caseInsensitiveCompare("starred") == .orderedSame
            }) { return true }
        }
        return false
    }

    func testStarStateFilterGate() {
        XCTAssertFalse(starFilterActive())
        XCTAssertTrue(starFilterActive(hide: ["CATEGORY_PROMOTIONS"]))
        XCTAssertTrue(starFilterActive(labelId: "STARRED"))
        XCTAssertTrue(starFilterActive(viewIsStarred: true))
        XCTAssertTrue(starFilterActive(viewLabelIsStarred: true))
        XCTAssertTrue(starFilterActive(savedStarredOnly: true))
        XCTAssertTrue(starFilterActive(savedExcludePromotionsLegacy: true))
        XCTAssertTrue(starFilterActive(search: "is:starred"))
        XCTAssertTrue(starFilterActive(search: "from:alice is:starred"))
        XCTAssertTrue(starFilterActive(search: "label:starred"))
        XCTAssertTrue(starFilterActive(search: "label:STARRED"))
        XCTAssertFalse(starFilterActive(search: "is:unread"))
        XCTAssertFalse(starFilterActive(search: "invoice"))
        XCTAssertFalse(starFilterActive(search: "label:work"))
    }

    func testLabelStarredFilterKeepIds() throws {
        // Mirrors MailStore.filterThreads STARRED + starKeepIds SQL.
        let db = try makeDB()
        try db.write { db in
            try makeThread(id: "s1", subject: "Just unstarred",
                           isStarred: false).insert(db)
            try makeThread(id: "s2", subject: "Still starred",
                           isStarred: true).insert(db)
        }

        let without = try db.read { db -> [String] in
            try MailThread.all()
                .filter(sql: "isStarred = 1")
                .order(Column("subject").asc).fetchAll(db).map(\.subject)
        }
        XCTAssertEqual(without, ["Still starred"])

        let withKeep = try db.read { db -> [String] in
            try MailThread.all()
                .filter(sql: "(isStarred = 1 OR id IN (?))",
                        arguments: ["a:s1"])
                .order(Column("subject").asc).fetchAll(db).map(\.subject)
        }
        XCTAssertEqual(withKeep, ["Just unstarred", "Still starred"])
    }

    /// Optimistic leave-list for Starred: unstarred + keep stays; without leave.
    func testOptimisticStarredLeaveRespectsKeepIds() {
        // Mirrors threadLeavesCurrentList(.starred):
        // !isStarred && !starStateKeepIds.contains(id)
        func leaves(isStarred: Bool, keep: Bool) -> Bool {
            !isStarred && !keep
        }
        XCTAssertFalse(leaves(isStarred: true, keep: false))
        XCTAssertTrue(leaves(isStarred: false, keep: false))
        XCTAssertFalse(leaves(isStarred: false, keep: true),
                       "pin before mutate must prevent optimistic remove")
    }
}
