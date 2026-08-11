import XCTest

/// Recipient chips were remove-only (×). Click should re-open the address in
/// the draft field so typos are fixable without retyping. These tests pin the
/// pure state transition the UI field uses — including the shared `commit`
/// path that focus-loss and click-to-edit both route through.
final class TokenAddressEditingTests: XCTestCase {

    // MARK: - commit (blur / Return / trailing comma)

    func testCommitAppendsValidAddressAndClearsDraft() {
        let result = TokenAddressEditing.commit(tokens: [], draft: "a@x.com")
        XCTAssertEqual(result.tokens, ["a@x.com"])
        XCTAssertEqual(result.draft, "")
    }

    func testCommitTrimsCommaAndWhitespace() {
        let result = TokenAddressEditing.commit(tokens: [], draft: " a@x.com, ")
        XCTAssertEqual(result.tokens, ["a@x.com"])
        XCTAssertEqual(result.draft, "")
    }

    func testCommitDoesNotDuplicateExistingToken() {
        let result = TokenAddressEditing.commit(
            tokens: ["a@x.com", "b@y.com"],
            draft: "b@y.com")
        XCTAssertEqual(result.tokens, ["a@x.com", "b@y.com"])
        XCTAssertEqual(result.draft, "")
    }

    func testCommitDiscardsIncompleteDraft() {
        let result = TokenAddressEditing.commit(tokens: ["a@x.com"], draft: "half")
        XCTAssertEqual(result.tokens, ["a@x.com"])
        XCTAssertEqual(result.draft, "")
    }

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

    /// Focus-loss path already committed: `beginEdit` with empty draft is the
    /// real UI order when clicking a chip while the TextField had focus.
    func testBeginEditAfterFocusLossCommitStillWorks() {
        // Simulate: commit ran first (draft cleared, token already a chip).
        let afterFocus = TokenAddressEditing.commit(
            tokens: ["a@x.com"],
            draft: "b@y.com")
        XCTAssertEqual(afterFocus.tokens, ["a@x.com", "b@y.com"])
        let edit = TokenAddressEditing.beginEdit(
            tokens: afterFocus.tokens,
            draft: afterFocus.draft,
            token: "a@x.com")
        XCTAssertEqual(edit.tokens, ["b@y.com"])
        XCTAssertEqual(edit.draft, "a@x.com")
    }

    /// Pending draft equals the chip being edited — commit then remove leaves
    /// no duplicate, draft reloads that address.
    func testBeginEditWhenDraftEqualsClickedToken() {
        let result = TokenAddressEditing.beginEdit(
            tokens: ["a@x.com"],
            draft: "a@x.com",
            token: "a@x.com")
        XCTAssertEqual(result.tokens, [])
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

    // MARK: - Gmail-style selection (Backspace / ← first highlights)

    func testBackspaceEmptyDraftSelectsLastChip() {
        let outcome = TokenAddressEditing.handleBackspace(
            tokens: ["a@x.com", "b@y.com"],
            draftIsEmpty: true,
            selection: nil)
        XCTAssertEqual(outcome, .select(.single(1)))
    }

    func testBackspaceWithSelectionRemovesSelectedChips() {
        let sel = TokenAddressEditing.ChipSelection(anchor: 0, focus: 1)
        let outcome = TokenAddressEditing.handleBackspace(
            tokens: ["a@x.com", "b@y.com", "c@z.com"],
            draftIsEmpty: true,
            selection: sel)
        XCTAssertEqual(outcome, .remove(tokens: ["c@z.com"], selection: nil))
    }

    func testBackspaceWithSingleSelectionRemovesOnlyThatChip() {
        let outcome = TokenAddressEditing.handleBackspace(
            tokens: ["a@x.com", "b@y.com", "c@z.com"],
            draftIsEmpty: true,
            selection: .single(1))
        XCTAssertEqual(outcome, .remove(tokens: ["a@x.com", "c@z.com"], selection: nil))
    }

    func testBackspaceIgnoresWhenDraftHasText() {
        let outcome = TokenAddressEditing.handleBackspace(
            tokens: ["a@x.com"],
            draftIsEmpty: false,
            selection: nil)
        XCTAssertEqual(outcome, .ignore)
    }

    /// Selection owns delete even if draft text is present (Cmd+X path).
    func testBackspaceWithSelectionRemovesEvenWhenDraftHasText() {
        let outcome = TokenAddressEditing.handleBackspace(
            tokens: ["a@x.com", "b@y.com"],
            draftIsEmpty: false,
            selection: .single(0))
        XCTAssertEqual(outcome, .remove(tokens: ["b@y.com"], selection: nil))
    }

    /// Forward-delete must not start a selection (Gmail).
    func testBackspaceDisallowSelectIsNoOpWithoutSelection() {
        let outcome = TokenAddressEditing.handleBackspace(
            tokens: ["a@x.com", "b@y.com"],
            draftIsEmpty: true,
            selection: nil,
            allowSelect: false)
        XCTAssertEqual(outcome, .ignore)
    }

    func testBackspaceDisallowSelectStillRemovesSelection() {
        let outcome = TokenAddressEditing.handleBackspace(
            tokens: ["a@x.com", "b@y.com"],
            draftIsEmpty: true,
            selection: .single(1),
            allowSelect: false)
        XCTAssertEqual(outcome, .remove(tokens: ["a@x.com"], selection: nil))
    }

    func testBackspaceIgnoresWhenNoTokens() {
        let outcome = TokenAddressEditing.handleBackspace(
            tokens: [],
            draftIsEmpty: true,
            selection: nil)
        XCTAssertEqual(outcome, .ignore)
    }

    func testLeftArrowEmptyDraftSelectsLastChip() {
        let sel = TokenAddressEditing.moveSelection(
            tokens: ["a@x.com", "b@y.com"],
            selection: nil,
            direction: .left,
            extend: false,
            draftIsEmpty: true)
        XCTAssertEqual(sel, .single(1))
    }

    func testLeftArrowMovesSelectionLeft() {
        let sel = TokenAddressEditing.moveSelection(
            tokens: ["a@x.com", "b@y.com", "c@z.com"],
            selection: .single(2),
            direction: .left,
            extend: false,
            draftIsEmpty: true)
        XCTAssertEqual(sel, .single(1))
    }

    func testShiftLeftExtendsSelection() {
        let sel = TokenAddressEditing.moveSelection(
            tokens: ["a@x.com", "b@y.com", "c@z.com"],
            selection: .single(2),
            direction: .left,
            extend: true,
            draftIsEmpty: true)
        XCTAssertEqual(sel, TokenAddressEditing.ChipSelection(anchor: 2, focus: 1))
        XCTAssertEqual(sel?.range, 1...2)
    }

    func testRightArrowPastLastClearsSelection() {
        let sel = TokenAddressEditing.moveSelection(
            tokens: ["a@x.com", "b@y.com"],
            selection: .single(1),
            direction: .right,
            extend: false,
            draftIsEmpty: true)
        XCTAssertNil(sel)
    }

    func testRightArrowEmptyDraftIsNoOp() {
        let sel = TokenAddressEditing.moveSelection(
            tokens: ["a@x.com"],
            selection: nil,
            direction: .right,
            extend: false,
            draftIsEmpty: true)
        XCTAssertNil(sel)
    }

    func testLeftArrowClampsAtFirstChip() {
        let sel = TokenAddressEditing.moveSelection(
            tokens: ["a@x.com", "b@y.com"],
            selection: .single(0),
            direction: .left,
            extend: false,
            draftIsEmpty: true)
        // At edge without extend: stay on first chip
        XCTAssertEqual(sel, .single(0))
    }

    func testRemoveSelectedRangeHighToLow() {
        let next = TokenAddressEditing.removeSelected(
            tokens: ["a@x.com", "b@y.com", "c@z.com", "d@w.com"],
            selection: TokenAddressEditing.ChipSelection(anchor: 1, focus: 2))
        XCTAssertEqual(next, ["a@x.com", "d@w.com"])
    }

    func testClampedSelectionAfterTokenShrink() {
        let sel = TokenAddressEditing.ChipSelection(anchor: 2, focus: 4)
        let clamped = TokenAddressEditing.clampedSelection(sel, tokenCount: 2)
        XCTAssertEqual(clamped, TokenAddressEditing.ChipSelection(anchor: 1, focus: 1))
    }

    func testClampedSelectionNilWhenEmpty() {
        XCTAssertNil(TokenAddressEditing.clampedSelection(.single(0), tokenCount: 0))
    }

    // MARK: - clipboard format (Gmail / Superhuman)

    func testClipboardNamedAddress() {
        let text = TokenAddressEditing.formatMailbox(
            email: "josh@glyphic.bio", name: "Josh Yang")
        XCTAssertEqual(text, "Josh Yang <josh@glyphic.bio>")
    }

    func testClipboardBareEmailWhenNoName() {
        XCTAssertEqual(
            TokenAddressEditing.formatMailbox(email: "josh@glyphic.bio", name: nil),
            "josh@glyphic.bio")
        XCTAssertEqual(
            TokenAddressEditing.formatMailbox(email: "josh@glyphic.bio", name: ""),
            "josh@glyphic.bio")
        XCTAssertEqual(
            TokenAddressEditing.formatMailbox(email: "josh@glyphic.bio", name: "josh@glyphic.bio"),
            "josh@glyphic.bio")
    }

    func testClipboardQuotesNameWithComma() {
        let text = TokenAddressEditing.formatMailbox(
            email: "jane@x.com", name: "Doe, Jane")
        XCTAssertEqual(text, "\"Doe, Jane\" <jane@x.com>")
    }

    func testClipboardQuotesNameWithQuotes() {
        let text = TokenAddressEditing.formatMailbox(
            email: "a@x.com", name: "Jo \"JJ\" Smith")
        XCTAssertEqual(text, "\"Jo \\\"JJ\\\" Smith\" <a@x.com>")
    }

    func testClipboardQuotesNameWithColonSemicolonAt() {
        XCTAssertEqual(
            TokenAddressEditing.formatMailbox(email: "a@x.com", name: "Team: Infra"),
            "\"Team: Infra\" <a@x.com>")
        XCTAssertEqual(
            TokenAddressEditing.formatMailbox(email: "a@x.com", name: "A; B"),
            "\"A; B\" <a@x.com>")
        XCTAssertEqual(
            TokenAddressEditing.formatMailbox(email: "a@x.com", name: "ron@home"),
            "\"ron@home\" <a@x.com>")
    }

    func testClipboardJoinsMultipleWithCommaSpace() {
        let names: [String: String] = [
            "josh@glyphic.bio": "Josh Yang",
            "alice@example.com": "Alice",
        ]
        let text = TokenAddressEditing.clipboardText(
            emails: ["josh@glyphic.bio", "bare@x.com", "alice@example.com"]
        ) { names[$0] }
        XCTAssertEqual(
            text,
            "Josh Yang <josh@glyphic.bio>, bare@x.com, Alice <alice@example.com>")
    }
}

