import XCTest

/// Draft card / banner hiding while the draft is open in a compose editor.
final class ComposingDraftVisibilityTests: XCTestCase {

    func testCardVisibleWhenNothingIsComposing() {
        XCTAssertFalse(ComposingDraftVisibility.hidesDraftCard(
            messageId: "a:d1", composingDraftIds: []))
    }

    func testCardHiddenForTheDraftOpenInCompose() {
        XCTAssertTrue(ComposingDraftVisibility.hidesDraftCard(
            messageId: "a:d1", composingDraftIds: ["a:d1"]))
    }

    func testOtherDraftInSameThreadStaysVisible() {
        XCTAssertFalse(
            ComposingDraftVisibility.hidesDraftCard(
                messageId: "a:d2", composingDraftIds: ["a:d1"]),
            "editing one draft must not hide a sibling draft's card")
    }

    func testAutosaveChainKeepsCardHidden() {
        // Autosave replaces the draft with a new Gmail message id; compose
        // registers both, so the card must not blink back mid-typing.
        let chain: Set<String> = ["a:d1", "a:d2"]
        XCTAssertTrue(ComposingDraftVisibility.hidesDraftCard(
            messageId: "a:d2", composingDraftIds: chain))
    }

    func testBannerNeedsLongThread() {
        XCTAssertFalse(ComposingDraftVisibility.showsDraftBanner(
            liveDraftIds: ["a:d1"], messageCount: 3, composingDraftIds: []))
        XCTAssertTrue(ComposingDraftVisibility.showsDraftBanner(
            liveDraftIds: ["a:d1"], messageCount: 4, composingDraftIds: []))
    }

    func testBannerHiddenWhenItsOnlyDraftIsComposing() {
        XCTAssertFalse(ComposingDraftVisibility.showsDraftBanner(
            liveDraftIds: ["a:d1"], messageCount: 6, composingDraftIds: ["a:d1"]))
    }

    func testBannerShownWhenAnotherDraftIsNotComposing() {
        XCTAssertTrue(ComposingDraftVisibility.showsDraftBanner(
            liveDraftIds: ["a:d1", "a:d2"], messageCount: 6,
            composingDraftIds: ["a:d1"]))
    }

    func testBannerHiddenWithoutLiveDrafts() {
        XCTAssertFalse(ComposingDraftVisibility.showsDraftBanner(
            liveDraftIds: [], messageCount: 9, composingDraftIds: []))
    }

    func testNoteAcceptedOnlyForActiveComposeRequest() {
        let active = UUID()
        let stale = UUID()
        XCTAssertTrue(ComposingDraftVisibility.acceptsComposingNote(
            requestId: active, activeComposeRequestId: active))
        XCTAssertFalse(ComposingDraftVisibility.acceptsComposingNote(
            requestId: stale, activeComposeRequestId: active),
            "late autosave from a replaced compose must not re-claim")
        XCTAssertFalse(ComposingDraftVisibility.acceptsComposingNote(
            requestId: active, activeComposeRequestId: nil),
            "closed compose must not accept notes")
    }

    /// Lifecycle the pure rules must pin: note → end → late note must not
    /// leave a permanent hide (Fable M1).
    func testLateNoteAfterEndDoesNotHideCard() {
        let requestId = UUID()
        let draftId = "a:d1"
        var claimed: Set<String> = []
        // Active compose claims the draft.
        if ComposingDraftVisibility.acceptsComposingNote(
            requestId: requestId, activeComposeRequestId: requestId) {
            claimed.insert(draftId)
        }
        XCTAssertTrue(ComposingDraftVisibility.hidesDraftCard(
            messageId: draftId, composingDraftIds: claimed))
        // Card unmounts / request ends.
        claimed.removeAll()
        // Late autosave tries to re-claim with a dead request (compose nil).
        if ComposingDraftVisibility.acceptsComposingNote(
            requestId: requestId, activeComposeRequestId: nil) {
            claimed.insert(draftId)
        }
        XCTAssertFalse(ComposingDraftVisibility.hidesDraftCard(
            messageId: draftId, composingDraftIds: claimed),
            "card must return after compose closes even if save finishes late")
    }
}
