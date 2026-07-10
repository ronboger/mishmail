import XCTest

final class AccountOrderTests: XCTestCase {
    // MARK: - moved

    func testMoveSwapsFirstTwo() {
        let result = AccountOrder.moved(["a", "b", "c"], from: IndexSet(integer: 0), to: 2)
        XCTAssertEqual(result, ["b", "a", "c"])
    }

    func testMoveToEnd() {
        let result = AccountOrder.moved(["a", "b", "c"], from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(result, ["b", "c", "a"])
    }

    func testMoveLastToFirst() {
        let result = AccountOrder.moved(["a", "b", "c"], from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(result, ["c", "a", "b"])
    }

    func testMoveNoOpWhenDestinationIsSameSpot() {
        let result = AccountOrder.moved(["a", "b", "c"], from: IndexSet(integer: 1), to: 1)
        XCTAssertEqual(result, ["a", "b", "c"])
    }

    // MARK: - reconciled

    func testReconciledKeepsPersistedOrder() {
        let result = AccountOrder.reconciled(persisted: ["b", "a", "c"], live: ["a", "b", "c"])
        XCTAssertEqual(result, ["b", "a", "c"])
    }

    func testReconciledAppendsUnknownLiveIds() {
        // "d" is a newly added account, not yet in the persisted order.
        let result = AccountOrder.reconciled(persisted: ["b", "a"], live: ["a", "b", "d"])
        XCTAssertEqual(result, ["b", "a", "d"])
    }

    func testReconciledDropsStaleIds() {
        // "z" was removed (account deleted / signed out); it must not linger.
        let result = AccountOrder.reconciled(persisted: ["z", "b", "a"], live: ["a", "b"])
        XCTAssertEqual(result, ["b", "a"])
    }

    func testReconciledWithEmptyPersistedOrderKeepsLiveOrder() {
        let result = AccountOrder.reconciled(persisted: [], live: ["a", "b", "c"])
        XCTAssertEqual(result, ["a", "b", "c"])
    }

    func testReconciledWithNoLiveAccountsReturnsEmpty() {
        let result = AccountOrder.reconciled(persisted: ["a", "b"], live: [])
        XCTAssertEqual(result, [])
    }
}
