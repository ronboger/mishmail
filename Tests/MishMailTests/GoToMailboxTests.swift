import XCTest

final class GoToMailboxTests: XCTestCase {
    func testGiOnInboxWithCommittedSearchClearsAndReloads() {
        let plan = GoToMailbox.plan(
            destinationIsCurrent: true,
            searchText: "from:alice",
            committedSearch: "from:alice")
        XCTAssertEqual(plan, GoToMailbox.Plan(
            clearSearch: true, changeView: false, reloadImmediately: true))
    }

    func testGiFromStarredWithSearchChangesViewAndClears() {
        let plan = GoToMailbox.plan(
            destinationIsCurrent: false,
            searchText: "invoice",
            committedSearch: "invoice")
        XCTAssertEqual(plan, GoToMailbox.Plan(
            clearSearch: true, changeView: true, reloadImmediately: false))
    }

    func testGiOnInboxWithoutSearchIsNoop() {
        let plan = GoToMailbox.plan(
            destinationIsCurrent: true,
            searchText: "",
            committedSearch: "")
        XCTAssertEqual(plan, GoToMailbox.Plan(
            clearSearch: false, changeView: false, reloadImmediately: false))
    }

    func testLiveSearchTextOnlyStillClears() {
        // Typed in the field but not yet committed — still leave the overlay.
        let plan = GoToMailbox.plan(
            destinationIsCurrent: true,
            searchText: "draft",
            committedSearch: "")
        XCTAssertTrue(plan.clearSearch)
        XCTAssertTrue(plan.reloadImmediately)
    }

    func testCrossViewWithoutSearchOnlyChangesView() {
        let plan = GoToMailbox.plan(
            destinationIsCurrent: false,
            searchText: "",
            committedSearch: "")
        XCTAssertEqual(plan, GoToMailbox.Plan(
            clearSearch: false, changeView: true, reloadImmediately: false))
    }
}
