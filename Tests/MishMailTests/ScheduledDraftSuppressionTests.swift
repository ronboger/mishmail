import XCTest

final class ScheduledDraftSuppressionTests: XCTestCase {

    func testUnionOfUndoSendAndScheduledDrafts() {
        XCTAssertEqual(
            ScheduledDraftSuppression.suppressedDraftIds(
                pendingSendDraftIds: ["a:d1"],
                scheduledDraftIds: ["a:d2", nil, "a:d3"]),
            ["a:d1", "a:d2", "a:d3"])
    }

    /// Nothing in memory after a relaunch: the scheduled rows alone must
    /// keep their drafts hidden.
    func testScheduledRowsAloneSuppressAfterRelaunch() {
        XCTAssertEqual(
            ScheduledDraftSuppression.suppressedDraftIds(
                pendingSendDraftIds: [], scheduledDraftIds: ["a:d2"]),
            ["a:d2"])
    }

    /// Cancel / edit / discard removes the row; its draft must show again.
    func testDraftShowsAgainWhenItsRowIsGone() {
        XCTAssertEqual(
            ScheduledDraftSuppression.suppressedDraftIds(
                pendingSendDraftIds: [], scheduledDraftIds: []),
            [])
    }

    /// "Send now" moves a row into the undo-send window: the row is gone
    /// but the draft stays hidden while the send is pending.
    func testDraftStaysHiddenWhileStillPendingSend() {
        XCTAssertEqual(
            ScheduledDraftSuppression.suppressedDraftIds(
                pendingSendDraftIds: ["a:d2"], scheduledDraftIds: []),
            ["a:d2"])
    }

    /// Two rows can name one draft (never by design, but rows are user
    /// data): dropping one must not unhide the draft the other still owns.
    func testDraftStaysHiddenWhileAnotherRowNamesIt() {
        XCTAssertEqual(
            ScheduledDraftSuppression.suppressedDraftIds(
                pendingSendDraftIds: [], scheduledDraftIds: ["a:d2", "a:d2"]),
            ["a:d2"])
    }

    func testEmptyDraftIdIsIgnored() {
        XCTAssertEqual(
            ScheduledDraftSuppression.suppressedDraftIds(
                pendingSendDraftIds: [], scheduledDraftIds: ["", nil]),
            [])
    }

    func testDraftsThatStillNeedAThread() {
        XCTAssertEqual(
            ScheduledDraftSuppression.draftsMissingThread(
                suppressed: ["a:d1", "a:d2"], threadByDraft: ["a:d1": "a:t1"]),
            ["a:d2"])
    }

    func testStaleThreadEntries() {
        XCTAssertEqual(
            ScheduledDraftSuppression.staleThreadEntries(
                suppressed: ["a:d1"], threadByDraft: ["a:d1": "a:t1", "a:d2": "a:t2"]),
            ["a:d2"])
    }

    /// The Drafts row of a conversation whose only draft is scheduled hides;
    /// a sibling draft that is not scheduled keeps the row.
    func testThreadWithOnlyAScheduledDraftIsSuppressed() {
        let suppressed = ScheduledDraftSuppression.suppressedDraftIds(
            pendingSendDraftIds: [], scheduledDraftIds: ["a:d2"])
        XCTAssertTrue(PendingDraftVisibility.suppressesThread(
            draftMessageIds: ["a:d2"], suppressing: suppressed))
        XCTAssertFalse(PendingDraftVisibility.suppressesThread(
            draftMessageIds: ["a:d2", "a:d9"], suppressing: suppressed))
    }
}
