import XCTest

/// 2026-09: Esc / ✕ (save and close) shared the "finished" flag with Send.
/// The guards that drop a late autosave after Send therefore also dropped the
/// close-path save, and deleted the draft an in-flight autosave had just
/// created — the whole message was gone. The rule is now per exit kind.
final class ComposeFinishTests: XCTestCase {
    func testSaveAndCloseKeepsALateDraftSave() {
        XCTAssertFalse(ComposeFinish.saveAndClose.dropsLateDraftSave)
    }

    /// The content left as mail (or was thrown away): a save that lands
    /// afterwards must not leave a stray draft behind.
    func testSendScheduleAndDiscardDropALateDraftSave() {
        XCTAssertTrue(ComposeFinish.send.dropsLateDraftSave)
        XCTAssertTrue(ComposeFinish.schedule.dropsLateDraftSave)
        XCTAssertTrue(ComposeFinish.discard.dropsLateDraftSave)
    }

    /// No explicit exit yet (still editing, or the card was replaced by a new
    /// compose and saves on unmount): the save must go through.
    func testNoFinishKeepsTheDraftSave() {
        XCTAssertFalse(ComposeFinish.dropsLateDraftSave(nil))
        XCTAssertFalse(ComposeFinish.dropsLateDraftSave(.saveAndClose))
        XCTAssertTrue(ComposeFinish.dropsLateDraftSave(.send))
    }
}
