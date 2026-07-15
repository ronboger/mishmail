import XCTest

/// Pinning a `/` search hit into the visible list so the reading pane can
/// resolve it (detail pane keys off `threads`, not just selectedThreadId).
final class OpenFromSearchTests: XCTestCase {

    private func thread(_ id: String, subject: String = "S") -> MailThread {
        MailThread(
            id: "a@x.com:\(id)", accountId: "a@x.com", gmailThreadId: id,
            subject: subject, snippet: "sn", fromDisplay: "F",
            lastDate: Date(), isUnread: false, isStarred: false,
            inInbox: true, inTrash: false,
            labelIds: "INBOX", snoozeUntil: nil, participants: "F",
            messageCount: 1, hasAttachment: false, reminderAt: nil)
    }

    func testEnsuringVisibleInsertsWhenMissing() {
        let a = thread("a")
        let b = thread("b")
        let out = OpenFromSearch.ensuringVisible(opening: b, in: [a])
        XCTAssertEqual(out.map(\.id), [b.id, a.id])
    }

    func testEnsuringVisibleNoOpWhenPresent() {
        let a = thread("a")
        let b = thread("b")
        let out = OpenFromSearch.ensuringVisible(opening: a, in: [a, b])
        XCTAssertEqual(out.map(\.id), [a.id, b.id], "must not duplicate or reorder")
    }

    func testMergingPinnedKeepsSelectedAcrossReloadGap() {
        let opened = thread("hit", subject: "From search")
        let other = thread("other")
        // Reload returned a different page that omits the open thread.
        let merged = OpenFromSearch.mergingPinned(
            selectedId: opened.id,
            previous: [opened, other],
            reloaded: [other])
        XCTAssertEqual(merged.map(\.id), [opened.id, other.id])
        XCTAssertEqual(merged.first?.subject, "From search")
    }

    func testMergingPinnedNoOpWhenAlreadyInReload() {
        let opened = thread("hit")
        let other = thread("other")
        let reloaded = [other, opened]
        let merged = OpenFromSearch.mergingPinned(
            selectedId: opened.id,
            previous: [opened],
            reloaded: reloaded)
        XCTAssertEqual(merged.map(\.id), reloaded.map(\.id),
                       "prefer the fresh reload order when already present")
    }

    func testMergingPinnedNoOpWithoutSelection() {
        let a = thread("a")
        let reloaded = [thread("b")]
        let merged = OpenFromSearch.mergingPinned(
            selectedId: nil,
            previous: [a],
            reloaded: reloaded)
        XCTAssertEqual(merged.map(\.id), reloaded.map(\.id))
    }

    func testMergingPinnedNoOpWhenPinMissingFromPrevious() {
        // Selection points at an id we no longer hold — can't reconstruct.
        let reloaded = [thread("b")]
        let merged = OpenFromSearch.mergingPinned(
            selectedId: "a@x.com:ghost",
            previous: [thread("a")],
            reloaded: reloaded)
        XCTAssertEqual(merged.map(\.id), reloaded.map(\.id))
    }

    // MARK: - Generation-scoped pin decision

    func testPinDecisionAppliesOnlyMatchingGenerationAndSelection() {
        XCTAssertEqual(
            OpenFromSearch.pinDecision(
                pendingThreadId: "t1", pendingGeneration: 6,
                completedGeneration: 6, currentSelectedId: "t1"),
            .apply(threadId: "t1"))
    }

    func testPinDecisionClearsWhenReloadSuperseded() {
        // openThread pinned gen 6; user typed a new query → gen 7 completes.
        XCTAssertEqual(
            OpenFromSearch.pinDecision(
                pendingThreadId: "t1", pendingGeneration: 6,
                completedGeneration: 7, currentSelectedId: "t1"),
            .clear,
            "must not pin a non-matching hit into a later reload's list")
    }

    func testPinDecisionClearsWhenSelectionMoved() {
        XCTAssertEqual(
            OpenFromSearch.pinDecision(
                pendingThreadId: "t1", pendingGeneration: 6,
                completedGeneration: 6, currentSelectedId: "t2"),
            .clear)
    }

    func testPinDecisionIgnoresWhenNoPinPending() {
        XCTAssertEqual(
            OpenFromSearch.pinDecision(
                pendingThreadId: nil, pendingGeneration: nil,
                completedGeneration: 6, currentSelectedId: "t1"),
            .ignore)
    }
}
