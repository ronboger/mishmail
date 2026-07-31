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
}
