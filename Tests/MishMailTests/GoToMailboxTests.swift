import XCTest

final class GoToMailboxTests: XCTestCase {
    func testGiOnInboxWithCommittedSearchClearsAndReloads() {
        let plan = GoToMailbox.plan(
            destinationIsCurrent: true,
            searchText: "from:alice",
            committedSearch: "from:alice")
        XCTAssertEqual(plan, GoToMailbox.Plan(
            clearSearch: true, changeView: false, reloadImmediately: true,
            exitThreadFocus: true, closeConversation: true))
    }

    func testGiFromStarredWithSearchChangesViewAndClears() {
        let plan = GoToMailbox.plan(
            destinationIsCurrent: false,
            searchText: "invoice",
            committedSearch: "invoice")
        XCTAssertEqual(plan, GoToMailbox.Plan(
            clearSearch: true, changeView: true, reloadImmediately: false,
            exitThreadFocus: true, closeConversation: true))
    }

    func testGiOnInboxWithoutSearchStillExitsThreadFocus() {
        // Same mailbox + no search: list/search flags are no-ops, but go-to
        // must still leave full-window conversation focus (g i ≈ back).
        let plan = GoToMailbox.plan(
            destinationIsCurrent: true,
            searchText: "",
            committedSearch: "")
        XCTAssertEqual(plan, GoToMailbox.Plan(
            clearSearch: false, changeView: false, reloadImmediately: false,
            exitThreadFocus: true, closeConversation: true))
    }

    func testGiOnCurrentMailboxClosesOpenConversation() {
        // g i on the mailbox you are already in must still land on the LIST.
        // With Ask Mish open the window narrows into compactDetail, where the
        // open conversation covers the list — exiting thread focus alone
        // changes nothing visible, so the plan must also close the
        // conversation (Gmail: g i always returns to the list).
        let plan = GoToMailbox.plan(
            destinationIsCurrent: true,
            searchText: "",
            committedSearch: "")
        XCTAssertTrue(plan.closeConversation)
    }

    func testLiveSearchTextOnlyStillClears() {
        // Typed in the field but not yet committed — still leave the overlay.
        let plan = GoToMailbox.plan(
            destinationIsCurrent: true,
            searchText: "draft",
            committedSearch: "")
        XCTAssertTrue(plan.clearSearch)
        XCTAssertTrue(plan.reloadImmediately)
        XCTAssertTrue(plan.exitThreadFocus)
    }

    func testCrossViewWithoutSearchOnlyChangesView() {
        let plan = GoToMailbox.plan(
            destinationIsCurrent: false,
            searchText: "",
            committedSearch: "")
        XCTAssertEqual(plan, GoToMailbox.Plan(
            clearSearch: false, changeView: true, reloadImmediately: false,
            exitThreadFocus: true, closeConversation: true))
    }
}
