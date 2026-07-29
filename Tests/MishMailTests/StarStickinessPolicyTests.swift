import XCTest

/// Pure policy / drop / category-hide leave tests for thread-long unstar
/// stickiness under category hide vs session stickiness under Starred.
final class StarStickinessPolicyTests: XCTestCase {

    // MARK: - Policy matrix

    func testPolicyNoneByDefault() {
        XCTAssertEqual(StarStickiness.policy(committedSearch: ""), .none)
    }

    func testPolicySessionForStarredMailbox() {
        XCTAssertEqual(
            StarStickiness.policy(committedSearch: "", viewIsStarred: true),
            .session)
    }

    func testPolicySessionForStarredLabelView() {
        XCTAssertEqual(
            StarStickiness.policy(committedSearch: "", viewLabelIsStarred: true),
            .session)
        XCTAssertEqual(
            StarStickiness.policy(committedSearch: "", chipsLabelId: "STARRED"),
            .session)
        XCTAssertEqual(
            StarStickiness.policy(committedSearch: "", savedLabelId: "STARRED"),
            .session)
    }

    func testPolicySessionForStarredOnlySavedView() {
        XCTAssertEqual(
            StarStickiness.policy(committedSearch: "", savedStarredOnly: true),
            .session)
    }

    func testPolicySessionForIsStarredSearch() {
        XCTAssertEqual(
            StarStickiness.policy(committedSearch: "is:starred"),
            .session)
        XCTAssertEqual(
            StarStickiness.policy(committedSearch: "from:bob is:starred"),
            .session)
        XCTAssertEqual(
            StarStickiness.policy(committedSearch: "label:starred"),
            .session)
        XCTAssertEqual(
            StarStickiness.policy(committedSearch: "label:STARRED"),
            .session)
    }

    func testPolicyThreadForCategoryHide() {
        XCTAssertEqual(
            StarStickiness.policy(
                committedSearch: "",
                chipsHide: ["CATEGORY_UPDATES"]),
            .thread)
        XCTAssertEqual(
            StarStickiness.policy(
                committedSearch: "",
                savedHide: ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL"]),
            .thread)
        XCTAssertEqual(
            StarStickiness.policy(
                committedSearch: "",
                savedExcludePromotionsLegacy: true),
            .thread)
    }

    func testPolicySessionWinsOverThreadWhenBothApply() {
        // starredOnly + hide → session (batch star triage must not vanish on j)
        XCTAssertEqual(
            StarStickiness.policy(
                committedSearch: "",
                chipsHide: ["CATEGORY_UPDATES"],
                savedStarredOnly: true),
            .session)
        XCTAssertEqual(
            StarStickiness.policy(
                committedSearch: "",
                chipsHide: ["CATEGORY_PROMOTIONS"],
                viewIsStarred: true),
            .session)
    }

    func testCommittedSearchMasksHideChips() {
        // Plain search replaces chips — hide must not arm thread stickiness.
        XCTAssertEqual(
            StarStickiness.policy(
                committedSearch: "invoice",
                chipsHide: ["CATEGORY_UPDATES"]),
            .none)
        XCTAssertEqual(
            StarStickiness.policy(
                committedSearch: "is:unread",
                chipsHide: ["CATEGORY_PROMOTIONS"]),
            .none)
    }

    // MARK: - Drop decision

    func testIdsToDropUnderThreadPolicy() {
        let keep: Set = ["a", "b", "c"]
        let dropped = StarStickiness.idsToDrop(
            keepIds: keep,
            selectedId: "a",
            checkedIds: ["b"],
            policy: .thread,
            selectionIntent: .click)
        XCTAssertEqual(dropped, ["c"])
    }

    func testIdsToDropEmptyUnderSessionPolicy() {
        let dropped = StarStickiness.idsToDrop(
            keepIds: ["a", "b"],
            selectedId: "z",
            checkedIds: [],
            policy: .session,
            selectionIntent: .click)
        XCTAssertTrue(dropped.isEmpty,
                      "session stickiness ignores selection leave")
    }

    func testRestoreFocusDoesNotDropThreadPins() {
        let dropped = StarStickiness.idsToDrop(
            keepIds: ["a", "b"],
            selectedId: "b",
            checkedIds: [],
            policy: .thread,
            selectionIntent: .restoreFocus)
        XCTAssertTrue(dropped.isEmpty,
                      "Undo restore must not yank pins for the prior focus")
    }

    func testBrowseAndAutoAdvanceDropThreadPins() {
        for intent: ThreadSelectionIntent in [.browse, .autoAdvance, .click, .explicitOpen] {
            let dropped = StarStickiness.idsToDrop(
                keepIds: ["old"],
                selectedId: "new",
                checkedIds: [],
                policy: .thread,
                selectionIntent: intent)
            XCTAssertEqual(dropped, ["old"], "intent \(intent) should drop")
        }
    }

    func testUncheckPassDropsWhenSelectionIntentNil() {
        // Uncheck / clear-checked: no selection intent — drop unretained.
        let dropped = StarStickiness.idsToDrop(
            keepIds: ["a", "b"],
            selectedId: "a",
            checkedIds: [],
            policy: .thread,
            selectionIntent: nil)
        XCTAssertEqual(dropped, ["b"])
    }

    func testCheckedRetainsPinWithoutSelection() {
        let dropped = StarStickiness.idsToDrop(
            keepIds: ["a", "b"],
            selectedId: nil,
            checkedIds: ["a"],
            policy: .thread,
            selectionIntent: nil)
        XCTAssertEqual(dropped, ["b"])
    }

    // MARK: - Category hide leave

    func testLeavesDueToCategoryHideUnstarredUpdates() {
        XCTAssertTrue(StarStickiness.leavesDueToCategoryHide(
            hide: ["CATEGORY_UPDATES"],
            inPromotions: false,
            inSocial: false,
            labelIds: "INBOX CATEGORY_UPDATES",
            isStarred: false,
            isKept: false))
    }

    func testStarPinsThroughCategoryHide() {
        XCTAssertFalse(StarStickiness.leavesDueToCategoryHide(
            hide: ["CATEGORY_UPDATES"],
            inPromotions: false,
            inSocial: false,
            labelIds: "INBOX CATEGORY_UPDATES STARRED",
            isStarred: true,
            isKept: false))
    }

    func testKeepIdsPinThroughCategoryHide() {
        XCTAssertFalse(StarStickiness.leavesDueToCategoryHide(
            hide: ["CATEGORY_UPDATES"],
            inPromotions: false,
            inSocial: false,
            labelIds: "INBOX CATEGORY_UPDATES",
            isStarred: false,
            isKept: true))
    }

    func testPromoDenormLeave() {
        XCTAssertTrue(StarStickiness.leavesDueToCategoryHide(
            hide: ["CATEGORY_PROMOTIONS"],
            inPromotions: true,
            inSocial: false,
            labelIds: "INBOX CATEGORY_PROMOTIONS",
            isStarred: false,
            isKept: false))
        XCTAssertFalse(StarStickiness.leavesDueToCategoryHide(
            hide: ["CATEGORY_PROMOTIONS"],
            inPromotions: false,
            inSocial: false,
            labelIds: "INBOX",
            isStarred: false,
            isKept: false))
    }

    func testEmptyHideNeverLeaves() {
        XCTAssertFalse(StarStickiness.leavesDueToCategoryHide(
            hide: [],
            inPromotions: true,
            inSocial: true,
            labelIds: "INBOX CATEGORY_UPDATES",
            isStarred: false,
            isKept: false))
    }

    /// Thread-long exit model: keep A while selected; leave selection → drop A.
    func testThreadLongExitModel() {
        var keepIds: Set = ["A"]
        // Still selected — retain.
        var drop = StarStickiness.idsToDrop(
            keepIds: keepIds, selectedId: "A", checkedIds: [],
            policy: .thread, selectionIntent: .browse)
        XCTAssertTrue(drop.isEmpty)
        // Move to B — drop A.
        drop = StarStickiness.idsToDrop(
            keepIds: keepIds, selectedId: "B", checkedIds: [],
            policy: .thread, selectionIntent: .browse)
        XCTAssertEqual(drop, ["A"])
        keepIds.subtract(drop)
        XCTAssertTrue(keepIds.isEmpty)
        // Without keep, unstarred Updates leaves Primary.
        XCTAssertTrue(StarStickiness.leavesDueToCategoryHide(
            hide: ["CATEGORY_UPDATES"],
            inPromotions: false, inSocial: false,
            labelIds: "INBOX CATEGORY_UPDATES",
            isStarred: false, isKept: false))
    }
}
