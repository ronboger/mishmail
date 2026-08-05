import XCTest

final class PrioritySplitTests: XCTestCase {
    private func thread(_ id: String, starred: Bool = false,
                        labels: String = "INBOX") -> MailThread {
        MailThread(id: "a@x.com:\(id)", accountId: "a@x.com", gmailThreadId: id,
                   subject: "s", snippet: "sn", fromDisplay: "F",
                   lastDate: Date(timeIntervalSince1970: 1000),
                   isUnread: false, isStarred: starred, inInbox: true,
                   inTrash: false, labelIds: labels, snoozeUntil: nil,
                   participants: "F", messageCount: 1, hasAttachment: false,
                   reminderAt: nil)
    }

    func testStarredImportantModeTakesBoth() {
        let threads = [thread("t1", starred: true),
                       thread("t2", labels: "INBOX IMPORTANT"),
                       thread("t3")]
        let (priority, rest) = PrioritySplit.partition(threads, mode: .starredImportant)
        XCTAssertEqual(priority.map(\.gmailThreadId), ["t1", "t2"])
        XCTAssertEqual(rest.map(\.gmailThreadId), ["t3"])
    }

    func testStarredModeIgnoresImportant() {
        let threads = [thread("t1", starred: true),
                       thread("t2", labels: "INBOX IMPORTANT"),
                       thread("t3")]
        let (priority, rest) = PrioritySplit.partition(threads, mode: .starred)
        XCTAssertEqual(priority.map(\.gmailThreadId), ["t1"])
        XCTAssertEqual(rest.map(\.gmailThreadId), ["t2", "t3"])
    }

    func testOrderPreservedAndNoDuplication() {
        let threads = [thread("t1"), thread("t2", starred: true, labels: "INBOX IMPORTANT"),
                       thread("t3"), thread("t4", starred: true)]
        let (priority, rest) = PrioritySplit.partition(threads, mode: .starredImportant)
        XCTAssertEqual(priority.map(\.gmailThreadId), ["t2", "t4"])
        XCTAssertEqual(rest.map(\.gmailThreadId), ["t1", "t3"])
        XCTAssertEqual(priority.count + rest.count, threads.count)
    }

    func testOffPassesEverythingThrough() {
        let threads = [thread("t1", starred: true), thread("t2")]
        let (priority, rest) = PrioritySplit.partition(threads, mode: .off)
        XCTAssertTrue(priority.isEmpty)
        XCTAssertEqual(rest.map(\.gmailThreadId), ["t1", "t2"])
    }

    func testVIPThreadPinsInAnyActiveMode() {
        let threads = [thread("t1"), thread("t2")]
        for mode in [PrioritySplit.Mode.starred, .starredImportant] {
            let (priority, rest) = PrioritySplit.partition(
                threads, mode: mode, vipThreadIds: ["a@x.com:t2"])
            XCTAssertEqual(priority.map(\.gmailThreadId), ["t2"], "mode \(mode)")
            XCTAssertEqual(rest.map(\.gmailThreadId), ["t1"], "mode \(mode)")
        }
    }

    func testVIPIgnoredWhenOff() {
        let threads = [thread("t1")]
        let (priority, _) = PrioritySplit.partition(
            threads, mode: .off, vipThreadIds: ["a@x.com:t1"])
        XCTAssertTrue(priority.isEmpty)
    }

    func testVIPsOnlyModePinsJustVIPs() {
        let threads = [thread("t1", starred: true),
                       thread("t2", labels: "INBOX IMPORTANT"),
                       thread("t3")]
        let (priority, rest) = PrioritySplit.partition(
            threads, mode: .vips, vipThreadIds: ["a@x.com:t3"])
        XCTAssertEqual(priority.map(\.gmailThreadId), ["t3"])
        XCTAssertEqual(rest.map(\.gmailThreadId), ["t1", "t2"])
    }

    func testVIPAlwaysPinsToggleOffExcludesVIPsFromStarredModes() {
        let threads = [thread("t1", starred: true), thread("t2")]
        for mode in [PrioritySplit.Mode.starred, .starredImportant] {
            let (priority, rest) = PrioritySplit.partition(
                threads, mode: mode, vipThreadIds: ["a@x.com:t2"],
                vipAlwaysPins: false)
            XCTAssertEqual(priority.map(\.gmailThreadId), ["t1"], "mode \(mode)")
            XCTAssertEqual(rest.map(\.gmailThreadId), ["t2"], "mode \(mode)")
        }
    }

    func testVIPAlwaysPinsToggleDoesNotAffectVIPsOnlyMode() {
        let threads = [thread("t1")]
        let (priority, _) = PrioritySplit.partition(
            threads, mode: .vips, vipThreadIds: ["a@x.com:t1"],
            vipAlwaysPins: false)
        XCTAssertEqual(priority.map(\.gmailThreadId), ["t1"])
    }

    func testParseEmailsHandlesMixedFreeFormText() {
        let text = """
        Ada Lovelace <ada@analytical.org>, grace@navy.mil
        turing@bletchley.uk; not-an-email
        ADA@analytical.org
        """
        XCTAssertEqual(PrioritySplit.parseEmails(text),
                       ["ada@analytical.org", "grace@navy.mil", "turing@bletchley.uk"])
    }

    func testParseEmailsEmptyAndJunk() {
        XCTAssertEqual(PrioritySplit.parseEmails(""), [])
        XCTAssertEqual(PrioritySplit.parseEmails("no addresses here @ all"), [])
    }

    func testImportantSubstringLabelDoesNotMatch() {
        // "UNIMPORTANT" or a user label containing the word must not qualify.
        let threads = [thread("t1", labels: "INBOX Label_UNIMPORTANT")]
        let (priority, _) = PrioritySplit.partition(threads, mode: .starredImportant)
        XCTAssertTrue(priority.isEmpty)
    }

    // MARK: - Hidden-category star pin-through (no Priority hoist)

    private func promoStarred(_ id: String) -> MailThread {
        var t = thread(id, starred: true, labels: "INBOX STARRED CATEGORY_PROMOTIONS")
        t.inPromotions = true
        return t
    }

    private func socialStarred(_ id: String) -> MailThread {
        var t = thread(id, starred: true, labels: "INBOX STARRED CATEGORY_SOCIAL")
        t.inSocial = true
        return t
    }

    func testStarredInHiddenPromotionsIsNotHoisted() {
        let t = promoStarred("t1")
        let hide: Set = ["CATEGORY_PROMOTIONS"]
        let (priority, rest) = PrioritySplit.partition(
            [t], mode: .starred, hiddenCategories: hide)
        XCTAssertTrue(priority.isEmpty)
        XCTAssertEqual(rest.map(\.gmailThreadId), ["t1"])
    }

    func testStarredInHiddenSocialIsNotHoisted() {
        let t = socialStarred("t1")
        let hide: Set = ["CATEGORY_SOCIAL"]
        let (priority, rest) = PrioritySplit.partition(
            [t], mode: .starred, hiddenCategories: hide)
        XCTAssertTrue(priority.isEmpty)
        XCTAssertEqual(rest.map(\.gmailThreadId), ["t1"])
    }

    func testStarredInHiddenUpdatesViaLabelIdsIsNotHoisted() {
        let t = thread("t1", starred: true,
                       labels: "INBOX STARRED CATEGORY_UPDATES")
        let hide: Set = ["CATEGORY_UPDATES"]
        let (priority, rest) = PrioritySplit.partition(
            [t], mode: .starred, hiddenCategories: hide)
        XCTAssertTrue(priority.isEmpty)
        XCTAssertEqual(rest.map(\.gmailThreadId), ["t1"])
    }

    func testStarredInHiddenForumsViaLabelIdsIsNotHoisted() {
        let t = thread("t1", starred: true,
                       labels: "INBOX STARRED CATEGORY_FORUMS")
        let hide: Set = ["CATEGORY_FORUMS"]
        let (priority, rest) = PrioritySplit.partition(
            [t], mode: .starredImportant, hiddenCategories: hide)
        XCTAssertTrue(priority.isEmpty)
        XCTAssertEqual(rest.map(\.gmailThreadId), ["t1"])
    }

    func testStarredIsHoistedWhenItsCategoryIsNotHidden() {
        let promo = promoStarred("promo")
        let updates = thread("upd", starred: true,
                             labels: "INBOX STARRED CATEGORY_UPDATES")
        // Hiding Social must not suppress Promotions / Updates stars.
        let hide: Set = ["CATEGORY_SOCIAL"]
        let (priority, rest) = PrioritySplit.partition(
            [promo, updates], mode: .starred, hiddenCategories: hide)
        XCTAssertEqual(priority.map(\.gmailThreadId), ["promo", "upd"])
        XCTAssertTrue(rest.isEmpty)
    }

    func testImportantInHiddenCategoryIsNotHoisted() {
        var t = thread("t1", labels: "INBOX IMPORTANT CATEGORY_PROMOTIONS")
        t.inPromotions = true
        let hide: Set = ["CATEGORY_PROMOTIONS"]
        let (priority, rest) = PrioritySplit.partition(
            [t], mode: .starredImportant, hiddenCategories: hide)
        XCTAssertTrue(priority.isEmpty)
        XCTAssertEqual(rest.map(\.gmailThreadId), ["t1"])
    }

    func testVIPInHiddenCategoryStillHoistsWithVipAlwaysPins() {
        let t = promoStarred("vip")
        let hide: Set = ["CATEGORY_PROMOTIONS"]
        for mode in [PrioritySplit.Mode.starred, .starredImportant] {
            let (priority, rest) = PrioritySplit.partition(
                [t], mode: mode, vipThreadIds: [t.id],
                vipAlwaysPins: true, hiddenCategories: hide)
            XCTAssertEqual(priority.map(\.gmailThreadId), ["vip"], "mode \(mode)")
            XCTAssertTrue(rest.isEmpty, "mode \(mode)")
        }
    }

    func testVIPsOnlyModeIgnoresHiddenCategories() {
        // .vips pins people, not categories — hide set is irrelevant.
        var t = thread("t1", labels: "INBOX CATEGORY_PROMOTIONS")
        t.inPromotions = true
        let (priority, rest) = PrioritySplit.partition(
            [t], mode: .vips, vipThreadIds: [t.id],
            hiddenCategories: ["CATEGORY_PROMOTIONS"])
        XCTAssertEqual(priority.map(\.gmailThreadId), ["t1"])
        XCTAssertTrue(rest.isEmpty)
    }

    func testEmptyHideSetBehavesAsBefore() {
        let threads = [promoStarred("t1"),
                       thread("t2", starred: true),
                       thread("t3")]
        let (priority, rest) = PrioritySplit.partition(
            threads, mode: .starred, hiddenCategories: [])
        XCTAssertEqual(priority.map(\.gmailThreadId), ["t1", "t2"])
        XCTAssertEqual(rest.map(\.gmailThreadId), ["t3"])
    }
}
