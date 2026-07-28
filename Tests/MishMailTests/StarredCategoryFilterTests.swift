import XCTest
import GRDB

/// Regression: hiding Promotions / Social / Updates / Forums in the inbox
/// filter bar must not drop starred threads. A star is an explicit pin — those
/// rows stay in the main list even when their Gmail category is filtered out.
///
/// Calls production `CategoryHide` SQL directly (hostless test target).
final class StarredCategoryFilterTests: XCTestCase {

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
        inSocial: Bool = false,
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
        t.inSocial = inSocial
        // Keep STARRED in the label blob when starring for realistic fixtures.
        if isStarred {
            let labels = Set(t.labelIds.split(separator: " ").map(String.init))
            if !labels.contains("STARRED") {
                t.labelIds = (t.labelIds + " STARRED").trimmingCharacters(in: .whitespaces)
            }
        }
        return t
    }

    private func subjects(
        _ db: Database,
        hide: Set<String>
    ) throws -> [String] {
        let q = CategoryHide.apply(MailThread.all(), hide: hide)
        return try q.order(Column("subject").asc).fetchAll(db).map(\.subject)
    }

    // MARK: - Tests

    func testStarredPromotionsSurviveDefaultInboxHide() throws {
        let db = try makeDB()
        try db.write { db in
            try makeThread(id: "p1", subject: "Promo plain",
                           isStarred: false, inPromotions: true,
                           labelIds: "INBOX CATEGORY_PROMOTIONS").insert(db)
            try makeThread(id: "p2", subject: "Promo starred",
                           isStarred: true, inPromotions: true,
                           labelIds: "INBOX CATEGORY_PROMOTIONS STARRED").insert(db)
            try makeThread(id: "i1", subject: "Primary",
                           isStarred: false,
                           labelIds: "INBOX").insert(db)
        }

        let hide: Set<String> = ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL"]
        let got = try db.read { try subjects($0, hide: hide) }
        XCTAssertEqual(got, ["Primary", "Promo starred"],
                       "starred promotions stay in the main list; unstarred do not")
    }

    func testStarredSocialSurvivesHide() throws {
        let db = try makeDB()
        try db.write { db in
            try makeThread(id: "s1", subject: "Social plain",
                           isStarred: false, inSocial: true,
                           labelIds: "INBOX CATEGORY_SOCIAL").insert(db)
            try makeThread(id: "s2", subject: "Social starred",
                           isStarred: true, inSocial: true,
                           labelIds: "INBOX CATEGORY_SOCIAL STARRED").insert(db)
        }

        let got = try db.read {
            try subjects($0, hide: ["CATEGORY_SOCIAL"])
        }
        XCTAssertEqual(got, ["Social starred"])
    }

    func testStarredUpdatesSurviveLabelIdsHide() throws {
        // Updates/Forums have no denorm columns — hide uses labelIds LIKE.
        let db = try makeDB()
        try db.write { db in
            try makeThread(id: "u1", subject: "Update plain",
                           isStarred: false,
                           labelIds: "INBOX CATEGORY_UPDATES").insert(db)
            try makeThread(id: "u2", subject: "Update starred",
                           isStarred: true,
                           labelIds: "INBOX CATEGORY_UPDATES STARRED").insert(db)
            try makeThread(id: "f1", subject: "Forum plain",
                           isStarred: false,
                           labelIds: "INBOX CATEGORY_FORUMS").insert(db)
            try makeThread(id: "f2", subject: "Forum starred",
                           isStarred: true,
                           labelIds: "INBOX CATEGORY_FORUMS STARRED").insert(db)
            try makeThread(id: "i1", subject: "Primary",
                           isStarred: false,
                           labelIds: "INBOX").insert(db)
        }

        let got = try db.read {
            try subjects($0, hide: ["CATEGORY_UPDATES", "CATEGORY_FORUMS"])
        }
        XCTAssertEqual(got, ["Forum starred", "Primary", "Update starred"])
    }

    func testLegacyExcludePromotionsKeepsStarred() throws {
        let db = try makeDB()
        try db.write { db in
            try makeThread(id: "p1", subject: "Promo plain",
                           isStarred: false, inPromotions: true).insert(db)
            try makeThread(id: "p2", subject: "Promo starred",
                           isStarred: true, inPromotions: true).insert(db)
            try makeThread(id: "s1", subject: "Social plain",
                           isStarred: false, inSocial: true).insert(db)
            try makeThread(id: "s2", subject: "Social starred",
                           isStarred: true, inSocial: true).insert(db)
            try makeThread(id: "i1", subject: "Primary",
                           isStarred: false).insert(db)
        }

        let got = try db.read { db -> [String] in
            try CategoryHide.applyExcludePromotions(MailThread.all())
                .order(Column("subject").asc)
                .fetchAll(db)
                .map(\.subject)
        }
        XCTAssertEqual(got, ["Primary", "Promo starred", "Social starred"])
    }

    func testUnstarredPrimaryStillShownWhenHidingCategories() throws {
        let db = try makeDB()
        try db.write { db in
            try makeThread(id: "i1", subject: "Primary unstarred",
                           isStarred: false).insert(db)
            try makeThread(id: "i2", subject: "Primary starred",
                           isStarred: true).insert(db)
        }
        let got = try db.read {
            try subjects($0, hide: ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL",
                                    "CATEGORY_UPDATES", "CATEGORY_FORUMS"])
        }
        XCTAssertEqual(got, ["Primary starred", "Primary unstarred"])
    }

    func testStarDoesNotOverrideMailboxScope() throws {
        // CategoryHide only pins past category tabs. Trash/archive still drop
        // the row once the full inbox base query is applied.
        let db = try makeDB()
        try db.write { db in
            try makeThread(id: "t1", subject: "Starred trashed promo",
                           isStarred: true, inPromotions: true,
                           inInbox: false, inTrash: true,
                           labelIds: "TRASH CATEGORY_PROMOTIONS STARRED").insert(db)
            try makeThread(id: "a1", subject: "Starred archived promo",
                           isStarred: true, inPromotions: true,
                           inInbox: false, inTrash: false,
                           labelIds: "CATEGORY_PROMOTIONS STARRED").insert(db)
            try makeThread(id: "p1", subject: "Starred inbox promo",
                           isStarred: true, inPromotions: true,
                           inInbox: true, inTrash: false,
                           labelIds: "INBOX CATEGORY_PROMOTIONS STARRED").insert(db)
        }

        let got = try db.read { db -> [String] in
            // Mirror inbox baseQuery + CategoryHide (applyChips path).
            var q = MailThread.all()
                .filter(Column("inInbox") == true && Column("inTrash") == false)
            q = CategoryHide.apply(q, hide: ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL"])
            return try q.order(Column("subject").asc).fetchAll(db).map(\.subject)
        }
        XCTAssertEqual(got, ["Starred inbox promo"],
                       "star pin-through must not resurrect trash or archive")
    }
}
