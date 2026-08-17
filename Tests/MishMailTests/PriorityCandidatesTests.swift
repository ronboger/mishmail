import XCTest
import GRDB

/// Priority candidate fetch must be independent of the list page window so
/// category-hide toggles do not change which stars pin into Priority.
final class PriorityCandidatesTests: XCTestCase {

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
        lastDate: Date,
        isStarred: Bool = false,
        inPromotions: Bool = false,
        inSocial: Bool = false,
        inInbox: Bool = true,
        inTrash: Bool = false,
        labelIds: String = "INBOX"
    ) -> MailThread {
        var labels = labelIds
        if isStarred {
            let set = Set(labels.split(separator: " ").map(String.init))
            if !set.contains("STARRED") {
                labels = (labels + " STARRED").trimmingCharacters(in: .whitespaces)
            }
        }
        var t = MailThread(
            id: "a@x.com:\(id)", accountId: "a@x.com", gmailThreadId: id,
            subject: id, snippet: "sn", fromDisplay: "F",
            lastDate: lastDate, isUnread: false, isStarred: isStarred,
            inInbox: inInbox, inTrash: inTrash,
            labelIds: labels, snoozeUntil: nil, participants: "F",
            messageCount: 1, hasAttachment: false, reminderAt: nil)
        t.inPromotions = inPromotions
        t.inSocial = inSocial
        return t
    }

    /// Inbox-style filtered request: inInbox, not trash, optional category hide.
    private func listBase(
        hide: Set<String> = []
    ) -> QueryInterfaceRequest<MailThread> {
        var q = MailThread.all()
            .filter(Column("inInbox") == true && Column("inTrash") == false)
        q = CategoryHide.apply(q, hide: hide)
        return q
    }

    private func fetchPage(
        _ db: Database,
        hide: Set<String>,
        limit: Int,
        inboundSort: Bool = false
    ) throws -> [MailThread] {
        let key = ThreadListPaging.sortDateSQL(inboundSort: inboundSort)
        return try listBase(hide: hide)
            .order(sql: "\(key) DESC, id DESC")
            .limit(limit)
            .fetchAll(db)
    }

    private func fetchCandidates(
        _ db: Database,
        mode: PrioritySplit.Mode,
        hide: Set<String> = [],
        newerThan: Date? = nil,
        maxCount: Int = 0,
        inboundSort: Bool = false
    ) throws -> [MailThread] {
        let req = try XCTUnwrap(PriorityCandidates.request(
            listBase(hide: hide),
            mode: mode,
            hiddenCategories: hide,
            newerThan: newerThan,
            maxCount: maxCount,
            inboundSort: inboundSort))
        return try req.fetchAll(db)
    }

    // MARK: - Core regression (page window independence)

    func testCandidateSetStableWhenHidingUpdates() throws {
        // Many recent unstarred Updates fill a tiny page; an older Primary
        // star sits past the page limit. Hiding Updates must not change the
        // candidate set (it used to pull the star into the page only then).
        let db = try makeDB()
        let day: TimeInterval = 86_400
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try db.write { db in
            for i in 0..<5 {
                try makeThread(
                    id: "upd-\(i)",
                    lastDate: now.addingTimeInterval(-TimeInterval(i) * 60),
                    isStarred: false,
                    labelIds: "INBOX CATEGORY_UPDATES"
                ).insert(db)
            }
            try makeThread(
                id: "old-star",
                lastDate: now.addingTimeInterval(-3 * day),
                isStarred: true,
                labelIds: "INBOX STARRED"
            ).insert(db)
            try makeThread(
                id: "recent-star",
                lastDate: now.addingTimeInterval(-30),
                isStarred: true,
                labelIds: "INBOX STARRED"
            ).insert(db)
        }

        let pageLimit = 3
        let cutoff = now.addingTimeInterval(-7 * day)

        try db.read { db in
            let pageOpen = try fetchPage(db, hide: [], limit: pageLimit)
            XCTAssertFalse(pageOpen.map(\.gmailThreadId).contains("old-star"),
                           "compact page should miss the older star")
            XCTAssertTrue(pageOpen.map(\.gmailThreadId).contains("recent-star")
                          || pageOpen.map(\.gmailThreadId).contains("upd-0"))

            let candOpen = try fetchCandidates(
                db, mode: .starred, hide: [], newerThan: cutoff, maxCount: 10)
            let candHide = try fetchCandidates(
                db, mode: .starred, hide: ["CATEGORY_UPDATES"],
                newerThan: cutoff, maxCount: 10)

            XCTAssertEqual(Set(candOpen.map(\.id)), Set(candHide.map(\.id)),
                           "candidate set must be identical with/without Updates hide")
            XCTAssertEqual(Set(candOpen.map(\.gmailThreadId)),
                           ["old-star", "recent-star"])

            // After hide, page reaches the old star — but candidates already had it.
            let pageHide = try fetchPage(db, hide: ["CATEGORY_UPDATES"], limit: pageLimit)
            XCTAssertTrue(pageHide.map(\.gmailThreadId).contains("old-star")
                          || candHide.map(\.gmailThreadId).contains("old-star"))
        }
    }

    // MARK: - Window

    func testWindowExcludesOldStarWhenCutoffSet() throws {
        let db = try makeDB()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        try db.write { db in
            try makeThread(id: "in-window", lastDate: cutoff.addingTimeInterval(60),
                           isStarred: true).insert(db)
            try makeThread(id: "out-window", lastDate: cutoff.addingTimeInterval(-60),
                           isStarred: true).insert(db)
        }
        try db.read { db in
            let withCut = try fetchCandidates(
                db, mode: .starred, newerThan: cutoff, maxCount: 10)
            XCTAssertEqual(withCut.map(\.gmailThreadId), ["in-window"])

            let noCut = try fetchCandidates(
                db, mode: .starred, newerThan: nil, maxCount: 10)
            XCTAssertEqual(Set(noCut.map(\.gmailThreadId)),
                           ["in-window", "out-window"])
        }
    }

    // MARK: - Cap

    func testCapReturnsOnlyNNewest() throws {
        let db = try makeDB()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try db.write { db in
            for i in 0..<5 {
                try makeThread(
                    id: "s\(i)",
                    lastDate: base.addingTimeInterval(TimeInterval(i)),
                    isStarred: true
                ).insert(db)
            }
        }
        try db.read { db in
            let got = try fetchCandidates(db, mode: .starred, maxCount: 2)
            XCTAssertEqual(got.map(\.gmailThreadId), ["s4", "s3"])
        }
    }

    func testUncappedUsesHardLimitConstant() {
        XCTAssertEqual(PriorityCandidates.fetchLimit(maxCount: 0),
                       PriorityCandidates.uncappedFetchLimit)
        XCTAssertEqual(PriorityCandidates.fetchLimit(maxCount: -1),
                       PriorityCandidates.uncappedFetchLimit)
        XCTAssertEqual(PriorityCandidates.fetchLimit(maxCount: 10), 10)
        XCTAssertNil(PriorityCandidates.request(
            MailThread.all(), mode: .off))
        XCTAssertNil(PriorityCandidates.request(
            MailThread.all(), mode: .vips))
    }

    // MARK: - starredImportant + hidden categories

    func testStarredImportantHidesUnstarredImportantInHiddenCategory() throws {
        let db = try makeDB()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try db.write { db in
            let impPromo = makeThread(
                id: "imp-promo", lastDate: now,
                isStarred: false, inPromotions: true,
                labelIds: "INBOX IMPORTANT CATEGORY_PROMOTIONS")
            try impPromo.insert(db)

            let impPrimary = makeThread(
                id: "imp-primary", lastDate: now.addingTimeInterval(-10),
                isStarred: false,
                labelIds: "INBOX IMPORTANT")
            try impPrimary.insert(db)

            try makeThread(
                id: "star-promo", lastDate: now.addingTimeInterval(-20),
                isStarred: true, inPromotions: true,
                labelIds: "INBOX STARRED CATEGORY_PROMOTIONS"
            ).insert(db)
        }

        // Without CategoryHide on the base (test the filter itself): hide promo.
        try db.read { db in
            let base = MailThread.all()
                .filter(Column("inInbox") == true && Column("inTrash") == false)
            let hide: Set = ["CATEGORY_PROMOTIONS"]
            let req = try XCTUnwrap(PriorityCandidates.request(
                base, mode: .starredImportant,
                hiddenCategories: hide, maxCount: 10, inboundSort: false))
            let ids = try req.fetchAll(db).map(\.gmailThreadId)
            XCTAssertFalse(ids.contains("imp-promo"),
                           "unstarred IMPORTANT in hidden category excluded")
            XCTAssertTrue(ids.contains("imp-primary"),
                          "unstarred IMPORTANT in visible category included")
            XCTAssertTrue(ids.contains("star-promo"),
                          "starred in hidden category always included")
        }
    }

    func testStarredImportantUpdatesLabelHide() throws {
        let db = try makeDB()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try db.write { db in
            try makeThread(
                id: "imp-upd", lastDate: now, isStarred: false,
                labelIds: "INBOX IMPORTANT CATEGORY_UPDATES"
            ).insert(db)
            try makeThread(
                id: "star-upd", lastDate: now.addingTimeInterval(-5),
                isStarred: true,
                labelIds: "INBOX STARRED CATEGORY_UPDATES"
            ).insert(db)
        }
        try db.read { db in
            let base = MailThread.all()
            let hide: Set = ["CATEGORY_UPDATES"]
            let req = try XCTUnwrap(PriorityCandidates.request(
                base, mode: .starredImportant,
                hiddenCategories: hide, maxCount: 10, inboundSort: false))
            let ids = try req.fetchAll(db).map(\.gmailThreadId)
            XCTAssertFalse(ids.contains("imp-upd"))
            XCTAssertTrue(ids.contains("star-upd"))
        }
    }

    // MARK: - Merge helper

    func testMergeDedupesAndInsertsAtCorrectPosition() {
        let d: (TimeInterval) -> Date = { Date(timeIntervalSince1970: $0) }
        let page = [
            makeThread(id: "p1", lastDate: d(100)),
            makeThread(id: "p2", lastDate: d(80)),
            makeThread(id: "p3", lastDate: d(60)),
        ]
        // Candidate already on page (p2) + one newer gap + one older than page.
        let candidates = [
            makeThread(id: "c-new", lastDate: d(90), isStarred: true),
            makeThread(id: "p2", lastDate: d(80), isStarred: true),
            makeThread(id: "c-old", lastDate: d(50), isStarred: true),
        ]
        let merged = PriorityCandidates.merge(
            page: page, candidates: candidates, inboundSort: false)
        XCTAssertEqual(merged.map(\.gmailThreadId),
                       ["p1", "c-new", "p2", "p3", "c-old"])
        // Page row identity preserved on conflict (same id).
        XCTAssertEqual(merged.filter { $0.gmailThreadId == "p2" }.count, 1)
    }

    func testMergePreservesPageOrderWithIdTieBreak() {
        let day = Date(timeIntervalSince1970: 1_000)
        // Same lastDate: id DESC places "z" before "a".
        let page = [
            makeThread(id: "z", lastDate: day),
            makeThread(id: "a", lastDate: day),
        ]
        let candidates = [
            makeThread(id: "m", lastDate: day, isStarred: true),
        ]
        let merged = PriorityCandidates.merge(
            page: page, candidates: candidates, inboundSort: false)
        // Full ids are "a@x.com:…" — DESC id order among equal dates.
        let ids = merged.map(\.id)
        for i in 0..<(ids.count - 1) {
            XCTAssertGreaterThanOrEqual(ids[i], ids[i + 1],
                                        "must stay sorted id DESC on date ties")
        }
        XCTAssertEqual(Set(merged.map(\.gmailThreadId)), ["z", "m", "a"])
    }

    func testMergeEmptyCandidatesIsIdentity() {
        let page = [makeThread(id: "p1", lastDate: Date())]
        XCTAssertEqual(
            PriorityCandidates.merge(page: page, candidates: [], inboundSort: false)
                .map(\.id),
            page.map(\.id))
    }

    /// Load-older cursor must come from the unmerged page bottom. An older
    /// starred candidate in the merged list would otherwise become the
    /// watermark and skip every row between page-end and that candidate.
    func testPagingCursorIgnoresOlderMergedCandidates() {
        let d: (TimeInterval) -> Date = { Date(timeIntervalSince1970: $0) }
        let page = [
            makeThread(id: "p1", lastDate: d(100)),
            makeThread(id: "p2", lastDate: d(80)),
            makeThread(id: "p3", lastDate: d(60)),
        ]
        let candidates = [
            makeThread(id: "c-old", lastDate: d(50), isStarred: true),
        ]
        let merged = PriorityCandidates.merge(
            page: page, candidates: candidates, inboundSort: false)
        let pageCursor = ThreadListPaging.nextCursor(after: page, inboundSort: false)
        let mergedCursor = ThreadListPaging.nextCursor(after: merged, inboundSort: false)
        XCTAssertEqual(pageCursor?.id, page.last?.id)
        XCTAssertEqual(pageCursor?.sortDate, d(60))
        XCTAssertEqual(mergedCursor?.id, merged.last?.id)
        XCTAssertEqual(mergedCursor?.sortDate, d(50))
        XCTAssertNotEqual(pageCursor, mergedCursor,
                          "cursor must not follow an older merged-in candidate")
    }
}
