import XCTest

final class PrioritySplitTests: XCTestCase {
    private func thread(_ id: String, starred: Bool = false,
                        labels: String = "INBOX",
                        lastDate: Date = Date(timeIntervalSince1970: 1000)) -> MailThread {
        MailThread(id: "a@x.com:\(id)", accountId: "a@x.com", gmailThreadId: id,
                   subject: "s", snippet: "sn", fromDisplay: "F",
                   lastDate: lastDate,
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

    // MARK: - Hidden categories (stars always hoist; IMPORTANT-only suppressed)

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

    func testStarredInHiddenPromotionsIsHoisted() {
        let t = promoStarred("t1")
        let hide: Set = ["CATEGORY_PROMOTIONS"]
        for mode in [PrioritySplit.Mode.starred, .starredImportant] {
            let (priority, rest) = PrioritySplit.partition(
                [t], mode: mode, hiddenCategories: hide)
            XCTAssertEqual(priority.map(\.gmailThreadId), ["t1"], "mode \(mode)")
            XCTAssertTrue(rest.isEmpty, "mode \(mode)")
        }
    }

    func testStarredInHiddenSocialIsHoisted() {
        let t = socialStarred("t1")
        let hide: Set = ["CATEGORY_SOCIAL"]
        for mode in [PrioritySplit.Mode.starred, .starredImportant] {
            let (priority, rest) = PrioritySplit.partition(
                [t], mode: mode, hiddenCategories: hide)
            XCTAssertEqual(priority.map(\.gmailThreadId), ["t1"], "mode \(mode)")
            XCTAssertTrue(rest.isEmpty, "mode \(mode)")
        }
    }

    func testStarredInHiddenUpdatesViaLabelIdsIsHoisted() {
        let t = thread("t1", starred: true,
                       labels: "INBOX STARRED CATEGORY_UPDATES")
        let hide: Set = ["CATEGORY_UPDATES"]
        for mode in [PrioritySplit.Mode.starred, .starredImportant] {
            let (priority, rest) = PrioritySplit.partition(
                [t], mode: mode, hiddenCategories: hide)
            XCTAssertEqual(priority.map(\.gmailThreadId), ["t1"], "mode \(mode)")
            XCTAssertTrue(rest.isEmpty, "mode \(mode)")
        }
    }

    func testStarredInHiddenForumsViaLabelIdsIsHoisted() {
        let t = thread("t1", starred: true,
                       labels: "INBOX STARRED CATEGORY_FORUMS")
        let hide: Set = ["CATEGORY_FORUMS"]
        for mode in [PrioritySplit.Mode.starred, .starredImportant] {
            let (priority, rest) = PrioritySplit.partition(
                [t], mode: mode, hiddenCategories: hide)
            XCTAssertEqual(priority.map(\.gmailThreadId), ["t1"], "mode \(mode)")
            XCTAssertTrue(rest.isEmpty, "mode \(mode)")
        }
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

    func testImportantOnlyInHiddenCategoryIsNotHoisted() {
        var t = thread("t1", labels: "INBOX IMPORTANT CATEGORY_PROMOTIONS")
        t.inPromotions = true
        let hide: Set = ["CATEGORY_PROMOTIONS"]
        let (priority, rest) = PrioritySplit.partition(
            [t], mode: .starredImportant, hiddenCategories: hide)
        XCTAssertTrue(priority.isEmpty)
        XCTAssertEqual(rest.map(\.gmailThreadId), ["t1"])
    }

    func testImportantOnlyInNonHiddenCategoryIsHoisted() {
        var t = thread("t1", labels: "INBOX IMPORTANT CATEGORY_PROMOTIONS")
        t.inPromotions = true
        // Hiding Social must not suppress an IMPORTANT Promotions thread.
        let hide: Set = ["CATEGORY_SOCIAL"]
        let (priority, rest) = PrioritySplit.partition(
            [t], mode: .starredImportant, hiddenCategories: hide)
        XCTAssertEqual(priority.map(\.gmailThreadId), ["t1"])
        XCTAssertTrue(rest.isEmpty)
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

    // MARK: - Recency window (newerThan)

    func testCutoffDaysZeroOrNegativeReturnsNil() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNil(PrioritySplit.cutoff(days: 0, now: now))
        XCTAssertNil(PrioritySplit.cutoff(days: -3, now: now))
    }

    func testCutoffDaysSevenIsNowMinusSevenDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cut = PrioritySplit.cutoff(days: 7, now: now)
        XCTAssertEqual(cut, now.addingTimeInterval(-7 * 86_400))
    }

    func testStarredInsideWindowHoistsOutsideDoesNot() {
        let cutoff = Date(timeIntervalSince1970: 10_000)
        let recent = thread("recent", starred: true,
                            lastDate: Date(timeIntervalSince1970: 10_001))
        let old = thread("old", starred: true,
                         lastDate: Date(timeIntervalSince1970: 9_999))
        for mode in [PrioritySplit.Mode.starred, .starredImportant] {
            let (priority, rest) = PrioritySplit.partition(
                [recent, old], mode: mode, newerThan: cutoff)
            XCTAssertEqual(priority.map(\.gmailThreadId), ["recent"], "mode \(mode)")
            XCTAssertEqual(rest.map(\.gmailThreadId), ["old"], "mode \(mode)")
        }
    }

    func testNilNewerThanKeepsUnfilteredStarHoist() {
        // Default parameter / nil window: old stars still hoist (pre-window behavior).
        let old = thread("old", starred: true,
                         lastDate: Date(timeIntervalSince1970: 1))
        for mode in [PrioritySplit.Mode.starred, .starredImportant] {
            let (priority, rest) = PrioritySplit.partition([old], mode: mode)
            XCTAssertEqual(priority.map(\.gmailThreadId), ["old"], "mode \(mode)")
            XCTAssertTrue(rest.isEmpty, "mode \(mode)")
        }
    }

    func testVIPOlderThanWindowStillHoistsWithVipAlwaysPins() {
        let cutoff = Date(timeIntervalSince1970: 10_000)
        let vip = thread("vip", lastDate: Date(timeIntervalSince1970: 1))
        for mode in [PrioritySplit.Mode.starred, .starredImportant] {
            let (priority, rest) = PrioritySplit.partition(
                [vip], mode: mode, vipThreadIds: [vip.id],
                vipAlwaysPins: true, newerThan: cutoff)
            XCTAssertEqual(priority.map(\.gmailThreadId), ["vip"], "mode \(mode)")
            XCTAssertTrue(rest.isEmpty, "mode \(mode)")
        }
    }

    func testImportantOnlyInsideWindowHoistsOutsideDoesNot() {
        let cutoff = Date(timeIntervalSince1970: 10_000)
        let recent = thread("recent", labels: "INBOX IMPORTANT",
                            lastDate: Date(timeIntervalSince1970: 10_001))
        let old = thread("old", labels: "INBOX IMPORTANT",
                         lastDate: Date(timeIntervalSince1970: 9_999))
        let (priority, rest) = PrioritySplit.partition(
            [recent, old], mode: .starredImportant, newerThan: cutoff)
        XCTAssertEqual(priority.map(\.gmailThreadId), ["recent"])
        XCTAssertEqual(rest.map(\.gmailThreadId), ["old"])
    }

    // MARK: - maxCount cap

    func testCapNilOrZeroMeansNoCap() {
        XCTAssertNil(PrioritySplit.cap(0))
        XCTAssertNil(PrioritySplit.cap(-1))
        XCTAssertEqual(PrioritySplit.cap(10), 10)

        let threads = [
            thread("t1", starred: true, lastDate: Date(timeIntervalSince1970: 4)),
            thread("t2", starred: true, lastDate: Date(timeIntervalSince1970: 3)),
            thread("t3", starred: true, lastDate: Date(timeIntervalSince1970: 2)),
            thread("t4", starred: true, lastDate: Date(timeIntervalSince1970: 1)),
        ]
        // Default maxCount / nil: all four pin (pre-cap behavior).
        let (p1, r1) = PrioritySplit.partition(threads, mode: .starred)
        XCTAssertEqual(p1.map(\.gmailThreadId), ["t1", "t2", "t3", "t4"])
        XCTAssertTrue(r1.isEmpty)

        let (p2, r2) = PrioritySplit.partition(threads, mode: .starred, maxCount: 0)
        XCTAssertEqual(p2.map(\.gmailThreadId), ["t1", "t2", "t3", "t4"])
        XCTAssertTrue(r2.isEmpty)

        let (p3, r3) = PrioritySplit.partition(threads, mode: .starred, maxCount: nil)
        XCTAssertEqual(p3.map(\.gmailThreadId), ["t1", "t2", "t3", "t4"])
        XCTAssertTrue(r3.isEmpty)
    }

    func testMaxCountKeepsNewestQualifyingInOrder() {
        // Input is newest-first; cap 2 keeps the first two that qualify.
        let threads = [
            thread("t1", starred: true, lastDate: Date(timeIntervalSince1970: 4)),
            thread("t2", starred: true, lastDate: Date(timeIntervalSince1970: 3)),
            thread("t3", starred: true, lastDate: Date(timeIntervalSince1970: 2)),
            thread("t4", starred: true, lastDate: Date(timeIntervalSince1970: 1)),
        ]
        let (priority, rest) = PrioritySplit.partition(
            threads, mode: .starred, maxCount: 2)
        XCTAssertEqual(priority.map(\.gmailThreadId), ["t1", "t2"])
        XCTAssertEqual(rest.map(\.gmailThreadId), ["t3", "t4"])
    }

    func testVIPOverflowExemptFromCap() {
        // After two non-VIP stars fill the cap, a VIP still enters Priority;
        // a later non-VIP star stays in rest.
        let threads = [
            thread("s1", starred: true, lastDate: Date(timeIntervalSince1970: 4)),
            thread("s2", starred: true, lastDate: Date(timeIntervalSince1970: 3)),
            thread("vip", lastDate: Date(timeIntervalSince1970: 2)),
            thread("s3", starred: true, lastDate: Date(timeIntervalSince1970: 1)),
        ]
        let vipId = "a@x.com:vip"
        let (priority, rest) = PrioritySplit.partition(
            threads, mode: .starred,
            vipThreadIds: [vipId],
            vipAlwaysPins: true,
            maxCount: 2)
        XCTAssertEqual(priority.map(\.gmailThreadId), ["s1", "s2", "vip"])
        XCTAssertEqual(rest.map(\.gmailThreadId), ["s3"])
    }

    func testCapComposesWithNewerThan() {
        // Old starred threads are outside the window — they don't consume slots.
        let cutoff = Date(timeIntervalSince1970: 10_000)
        let threads = [
            thread("r1", starred: true, lastDate: Date(timeIntervalSince1970: 10_003)),
            thread("r2", starred: true, lastDate: Date(timeIntervalSince1970: 10_002)),
            thread("r3", starred: true, lastDate: Date(timeIntervalSince1970: 10_001)),
            thread("old", starred: true, lastDate: Date(timeIntervalSince1970: 9_999)),
        ]
        let (priority, rest) = PrioritySplit.partition(
            threads, mode: .starred, newerThan: cutoff, maxCount: 2)
        XCTAssertEqual(priority.map(\.gmailThreadId), ["r1", "r2"])
        XCTAssertEqual(rest.map(\.gmailThreadId), ["r3", "old"])
    }

    func testMaxCountAppliesToImportantOnlyInStarredImportantMode() {
        let threads = [
            thread("i1", labels: "INBOX IMPORTANT",
                   lastDate: Date(timeIntervalSince1970: 4)),
            thread("i2", labels: "INBOX IMPORTANT",
                   lastDate: Date(timeIntervalSince1970: 3)),
            thread("i3", labels: "INBOX IMPORTANT",
                   lastDate: Date(timeIntervalSince1970: 2)),
            thread("i4", labels: "INBOX IMPORTANT",
                   lastDate: Date(timeIntervalSince1970: 1)),
        ]
        let (priority, rest) = PrioritySplit.partition(
            threads, mode: .starredImportant, maxCount: 2)
        XCTAssertEqual(priority.map(\.gmailThreadId), ["i1", "i2"])
        XCTAssertEqual(rest.map(\.gmailThreadId), ["i3", "i4"])
    }
}
