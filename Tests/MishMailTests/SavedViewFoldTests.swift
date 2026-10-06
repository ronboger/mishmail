import XCTest

/// `MailStore.saveView` folds the ViewEditor's structured fields back into a
/// chips-backed saved view. The fold must be able to turn a filter OFF, not
/// only on — otherwise the editor shows a toggle as off while the list keeps
/// filtering.
final class SavedViewFoldTests: XCTestCase {
    private let promo = "CATEGORY_PROMOTIONS"
    private let social = "CATEGORY_SOCIAL"
    private let updates = "CATEGORY_UPDATES"

    // MARK: - Exclude Promotions & Social

    func testExcludePromotionsOnAddsBothCategories() {
        let out = SavedViewFold.categories(
            show: [], hide: [updates], excludePromotions: true, category: nil)
        XCTAssertEqual(out.hide, [promo, social, updates])
        XCTAssertEqual(out.show, [])
    }

    /// The defect: a view saved from the Inbox hides Promotions and Social;
    /// turning the toggle off in the editor left both hidden.
    func testExcludePromotionsOffRemovesBothCategories() {
        let out = SavedViewFold.categories(
            show: [], hide: [promo, social], excludePromotions: false, category: nil)
        XCTAssertEqual(out.hide, [])
    }

    func testExcludePromotionsOffKeepsOtherHiddenCategories() {
        let out = SavedViewFold.categories(
            show: [], hide: [promo, social, updates],
            excludePromotions: false, category: nil)
        XCTAssertEqual(out.hide, [updates])
    }

    /// The toggle reads "on" only when BOTH categories are hidden, so a view
    /// that hides one of them shows the toggle off. Saving it unchanged (a
    /// rename) must not drop that single hide.
    func testExcludePromotionsOffKeepsSingleCategoryHide() {
        let promoOnly = SavedViewFold.categories(
            show: [], hide: [promo], excludePromotions: false, category: nil)
        XCTAssertEqual(promoOnly.hide, [promo])
        let socialAndUpdates = SavedViewFold.categories(
            show: [], hide: [social, updates], excludePromotions: false, category: nil)
        XCTAssertEqual(socialAndUpdates.hide, [social, updates])
    }

    // MARK: - Category

    /// The defect: Category "Promotions" → "Any" left the category filter on.
    func testCategoryAnyClearsShow() {
        let out = SavedViewFold.categories(
            show: [promo], hide: [], excludePromotions: false, category: nil)
        XCTAssertEqual(out.show, [])
    }

    func testCategoryPickReplacesShow() {
        let out = SavedViewFold.categories(
            show: [promo], hide: [], excludePromotions: false, category: updates)
        XCTAssertEqual(out.show, [updates])
    }

    func testCategoryAndExcludeAreIndependent() {
        let out = SavedViewFold.categories(
            show: [updates], hide: [promo, social],
            excludePromotions: true, category: updates)
        XCTAssertEqual(out.show, [updates])
        XCTAssertEqual(out.hide, [promo, social])
    }

    // MARK: - Label name

    func testLabelNameKeptWhileLabelUnchanged() {
        XCTAssertEqual(
            SavedViewFold.labelName(current: "Receipts", oldLabelId: "Label_1",
                                    newLabelId: "Label_1"),
            "Receipts")
    }

    /// The name is display-only; a stale one would name the wrong label.
    func testLabelNameDroppedWhenLabelChanges() {
        XCTAssertNil(SavedViewFold.labelName(
            current: "Receipts", oldLabelId: "Label_1", newLabelId: "Label_2"))
        XCTAssertNil(SavedViewFold.labelName(
            current: "Receipts", oldLabelId: "Label_1", newLabelId: nil))
    }
}
