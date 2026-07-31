import XCTest

final class ListReselectPolicyTests: XCTestCase {
    func testMountsHandlerOnlyWhenRowIsSelected() {
        XCTAssertTrue(ListReselectPolicy.mountsHandler(row: "inbox", selected: "inbox"))
        XCTAssertFalse(ListReselectPolicy.mountsHandler(row: "starred", selected: "inbox"))
        XCTAssertFalse(ListReselectPolicy.mountsHandler(row: "sent", selected: "drafts"))
        XCTAssertTrue(ListReselectPolicy.mountsHandler(row: "sent", selected: "sent"))
    }

    func testMountsHandlerUsesEquatableIdentity() {
        // MailboxView.saved compares id + name; reselect only when the List
        // tag is already selected (same identity as the selection binding).
        struct Tag: Equatable {
            var id: Int
            var name: String
        }
        let selected = Tag(id: 1, name: "Work")
        XCTAssertTrue(ListReselectPolicy.mountsHandler(
            row: selected, selected: selected))
        XCTAssertFalse(ListReselectPolicy.mountsHandler(
            row: Tag(id: 1, name: "Work renamed"), selected: selected))
        XCTAssertFalse(ListReselectPolicy.mountsHandler(
            row: Tag(id: 2, name: "Work"), selected: selected))
    }
}
