import XCTest

/// Recipient chips were remove-only (×). Click should re-open the address in
/// the draft field so typos are fixable without retyping. These tests pin the
/// pure state transition the UI field uses.
final class TokenAddressEditingTests: XCTestCase {

    // MARK: - beginEdit (click chip)

    func testClickChipLoadsAddressIntoDraftAndRemovesChip() {
        let result = TokenAddressEditing.beginEdit(
            tokens: ["a@x.com", "b@y.com"],
            draft: "",
            token: "a@x.com")
        XCTAssertEqual(result.tokens, ["b@y.com"])
        XCTAssertEqual(result.draft, "a@x.com")
    }

    func testClickMiddleChipPreservesNeighbors() {
        let result = TokenAddressEditing.beginEdit(
            tokens: ["a@x.com", "b@y.com", "c@z.com"],
            draft: "",
            token: "b@y.com")
        XCTAssertEqual(result.tokens, ["a@x.com", "c@z.com"])
        XCTAssertEqual(result.draft, "b@y.com")
    }

    /// A pending typed address must not be lost when the user clicks a chip.
    func testPendingValidDraftIsCommittedBeforeEdit() {
        let result = TokenAddressEditing.beginEdit(
            tokens: ["a@x.com"],
            draft: "new@z.com",
            token: "a@x.com")
        XCTAssertEqual(result.tokens, ["new@z.com"])
        XCTAssertEqual(result.draft, "a@x.com")
    }

    func testPendingDraftWithTrailingCommaIsCommitted() {
        let result = TokenAddressEditing.beginEdit(
            tokens: [],
            draft: "new@z.com, ",
            token: "kept@x.com")
        // token wasn't in the list — still becomes draft; cleaned draft commits
        XCTAssertEqual(result.tokens, ["new@z.com"])
        XCTAssertEqual(result.draft, "kept@x.com")
    }

    func testIncompleteDraftIsDiscardedOnEdit() {
        let result = TokenAddressEditing.beginEdit(
            tokens: ["a@x.com"],
            draft: "half-typed",
            token: "a@x.com")
        XCTAssertEqual(result.tokens, [])
        XCTAssertEqual(result.draft, "a@x.com")
    }

    func testDoesNotDuplicatePendingDraftAlreadyInTokens() {
        let result = TokenAddressEditing.beginEdit(
            tokens: ["a@x.com", "b@y.com"],
            draft: "b@y.com",
            token: "a@x.com")
        XCTAssertEqual(result.tokens, ["b@y.com"])
        XCTAssertEqual(result.draft, "a@x.com")
    }

    /// Duplicate chips: only the first match is opened for edit.
    func testEditRemovesOnlyFirstDuplicate() {
        let result = TokenAddressEditing.beginEdit(
            tokens: ["a@x.com", "a@x.com"],
            draft: "",
            token: "a@x.com")
        XCTAssertEqual(result.tokens, ["a@x.com"])
        XCTAssertEqual(result.draft, "a@x.com")
    }

    // MARK: - remove (× button)

    func testRemoveDropsFirstMatchOnly() {
        XCTAssertEqual(
            TokenAddressEditing.remove(tokens: ["a@x.com", "b@y.com", "a@x.com"],
                                       token: "a@x.com"),
            ["b@y.com", "a@x.com"])
    }

    func testRemoveMissingTokenIsNoOp() {
        XCTAssertEqual(
            TokenAddressEditing.remove(tokens: ["a@x.com"], token: "missing@z.com"),
            ["a@x.com"])
    }
}
