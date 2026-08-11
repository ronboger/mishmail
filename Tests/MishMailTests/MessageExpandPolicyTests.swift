import XCTest

/// Hostless suite: pure expand-set policy for reading pane vs side-by-side.
final class MessageExpandPolicyTests: XCTestCase {

    func testSingleToggleOpensAndClosesOne() {
        let policy = MessageExpandPolicy.single
        let opened = policy.applyingToggle(id: "a", currently: [])
        XCTAssertEqual(opened, ["a"])
        let closed = policy.applyingToggle(id: "a", currently: opened)
        XCTAssertEqual(closed, [])
    }

    func testSingleExpandReplacesSibling() {
        let policy = MessageExpandPolicy.single
        let next = policy.applyingExpand(id: "b", currently: ["a"])
        XCTAssertEqual(next, ["b"])
        let toggled = policy.applyingToggle(id: "c", currently: ["b"])
        XCTAssertEqual(toggled, ["c"])
    }

    func testMultipleToggleKeepsSiblings() {
        let policy = MessageExpandPolicy.multiple
        let a = policy.applyingToggle(id: "a", currently: [])
        let ab = policy.applyingToggle(id: "b", currently: a)
        XCTAssertEqual(ab, ["a", "b"])
        let onlyB = policy.applyingToggle(id: "a", currently: ab)
        XCTAssertEqual(onlyB, ["b"])
    }

    func testMultipleExpandAddsWithoutCollapsing() {
        let policy = MessageExpandPolicy.multiple
        let next = policy.applyingExpand(id: "b", currently: ["a"])
        XCTAssertEqual(next, ["a", "b"])
        // Already open is a no-op insert.
        XCTAssertEqual(policy.applyingExpand(id: "a", currently: next), ["a", "b"])
    }

    func testInitialExpandedIdsSingleUsesLastOnly() {
        let ids = MessageExpandPolicy.initialExpandedIds(
            policy: .single,
            nonDraftIds: ["m1", "m2", "m3"],
            lastNonDraftId: "m3")
        XCTAssertEqual(ids, ["m3"])
    }

    func testInitialExpandedIdsSingleEmptyWhenNoLast() {
        let ids = MessageExpandPolicy.initialExpandedIds(
            policy: .single,
            nonDraftIds: ["m1"],
            lastNonDraftId: nil)
        XCTAssertEqual(ids, [])
    }

    func testInitialExpandedIdsMultipleOpensAllNonDrafts() {
        let ids = MessageExpandPolicy.initialExpandedIds(
            policy: .multiple,
            nonDraftIds: ["m1", "m2", "m3"],
            lastNonDraftId: "m3")
        XCTAssertEqual(ids, ["m1", "m2", "m3"])
    }

    func testInitialExpandedIdsMultipleEmptyThread() {
        let ids = MessageExpandPolicy.initialExpandedIds(
            policy: .multiple,
            nonDraftIds: [],
            lastNonDraftId: nil)
        XCTAssertEqual(ids, [])
    }
}
