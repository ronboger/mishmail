import XCTest

/// "Save as view…" must save the list that is on screen. A saved view is an
/// inbox view unless its fields say otherwise, so the base mailbox (Sent,
/// Starred, All Mail, a label…) has to be written into those fields.
final class SavedViewBaseTests: XCTestCase {
    private func fields(
        _ source: SavedViewBase.Source,
        active: String? = nil,
        labelId: String? = nil,
        labelName: String? = nil,
        labelExclude: Bool = false,
        showArchived: Bool = false,
        show: Set<String> = []
    ) -> SavedViewBase.Fields? {
        SavedViewBase.fields(
            for: source, activeAccountId: active,
            chipsLabelId: labelId, chipsLabelName: labelName,
            chipsLabelExclude: labelExclude,
            chipsShowArchived: showArchived, chipsCategoryShow: show)
    }

    // MARK: - Inbox (unchanged behavior)

    func testInboxPassesTheChipsThrough() {
        let f = fields(.inbox, active: "a@x.com", labelId: "Label_1",
                       labelName: "Receipts", labelExclude: true,
                       showArchived: true, show: ["CATEGORY_UPDATES"])
        XCTAssertEqual(f, SavedViewBase.Fields(
            accountId: "a@x.com", labelId: "Label_1", labelName: "Receipts",
            labelExclude: true, starredOnly: false, showArchived: true,
            categoryShow: ["CATEGORY_UPDATES"]))
    }

    func testInboxStaysInboxScopedByDefault() {
        let f = fields(.inbox)
        XCTAssertEqual(f?.showArchived, false)
        XCTAssertNil(f?.accountId)
        XCTAssertNil(f?.labelId)
        XCTAssertEqual(f?.starredOnly, false)
    }

    func testAccountInboxScopesToThatAccount() {
        // The sidebar account row wins over the account switcher.
        let f = fields(.account("b@x.com"), active: nil)
        XCTAssertEqual(f?.accountId, "b@x.com")
        XCTAssertEqual(f?.showArchived, false)
    }

    // MARK: - Non-inbox bases

    func testSentBecomesTheSentLabelOverAllMail() {
        let f = fields(.sent, active: "a@x.com")
        XCTAssertEqual(f?.labelId, "SENT")
        XCTAssertEqual(f?.labelName, "Sent")
        XCTAssertEqual(f?.showArchived, true, "sent mail is not in the inbox")
        XCTAssertEqual(f?.accountId, "a@x.com")
        XCTAssertEqual(f?.starredOnly, false)
    }

    /// A cleared label chip can leave "does not contain" set. It must not
    /// turn the base label into "everything except Sent".
    func testBaseLabelIsNeverAnExcludeFilter() {
        XCTAssertEqual(fields(.sent, labelExclude: true)?.labelExclude, false)
        XCTAssertEqual(
            fields(.label(account: "a@x.com", labelId: "Label_7", name: "Deals"),
                   labelExclude: true)?.labelExclude,
            false)
    }

    func testStarredBecomesStarredOnlyOverAllMail() {
        let f = fields(.starred, labelId: "Label_1", labelName: "Receipts")
        XCTAssertEqual(f?.starredOnly, true)
        XCTAssertEqual(f?.showArchived, true)
        // The label chip is independent of the base and stays.
        XCTAssertEqual(f?.labelId, "Label_1")
        XCTAssertEqual(f?.labelName, "Receipts")
    }

    func testAllMailIncludesArchived() {
        let f = fields(.allMail)
        XCTAssertEqual(f?.showArchived, true)
        XCTAssertEqual(f?.starredOnly, false)
        XCTAssertNil(f?.labelId)
    }

    func testLabelViewKeepsItsLabelAndAccount() {
        let f = fields(.label(account: "b@x.com", labelId: "Label_7", name: "Deals"),
                       active: "a@x.com")
        XCTAssertEqual(f?.accountId, "b@x.com", "label ids are per account")
        XCTAssertEqual(f?.labelId, "Label_7")
        XCTAssertEqual(f?.labelName, "Deals")
        XCTAssertEqual(f?.showArchived, true)
    }

    func testCategoryTabsBecomeAnInboxCategoryFilter() {
        let promo = fields(.promotions, showArchived: true)
        XCTAssertEqual(promo?.categoryShow, ["CATEGORY_PROMOTIONS"])
        // The Promotions tab is inbox mail only; the chip does not widen it.
        XCTAssertEqual(promo?.showArchived, false)
        let social = fields(.social, show: ["CATEGORY_SOCIAL"])
        XCTAssertEqual(social?.categoryShow, ["CATEGORY_SOCIAL"])
    }

    // MARK: - No mapping → no button

    func testUnsupportedViewsHaveNoMapping() {
        XCTAssertNil(fields(.unsupported))
        XCTAssertNil(fields(.unsupported, active: "a@x.com", labelId: "Label_1"))
    }

    /// A saved view holds ONE label. Base label + label chip is "has both",
    /// which it cannot express — saving would silently drop one of them.
    func testBaseLabelPlusLabelChipHasNoMapping() {
        XCTAssertNil(fields(.sent, labelId: "Label_1"))
        XCTAssertNil(fields(.label(account: "a@x.com", labelId: "Label_7", name: "Deals"),
                            labelId: "Label_1"))
    }

    /// Shown categories are OR-ed. Promotions tab + "show Updates" on screen
    /// means both at once, which the saved set cannot express.
    func testCategoryTabPlusOtherShownCategoryHasNoMapping() {
        XCTAssertNil(fields(.promotions, show: ["CATEGORY_UPDATES"]))
        XCTAssertNil(fields(.social, show: ["CATEGORY_SOCIAL", "CATEGORY_FORUMS"]))
    }

    // MARK: - Editor label row

    func testUnlistedLabelTitle() {
        XCTAssertEqual(SavedViewBase.unlistedLabelTitle("SENT"), "Sent")
        XCTAssertEqual(SavedViewBase.unlistedLabelTitle("Label_404"), "Label_404")
    }
}
