import XCTest

final class SelectionAdvanceTests: XCTestCase {
    func testSelectionIntentOnlyDebouncesBrowsing() {
        XCTAssertFalse(ThreadSelectionIntent.browse.opensDetailImmediately)
        XCTAssertTrue(ThreadSelectionIntent.click.opensDetailImmediately)
        XCTAssertTrue(ThreadSelectionIntent.autoAdvance.opensDetailImmediately)
        XCTAssertTrue(ThreadSelectionIntent.explicitOpen.opensDetailImmediately)
        XCTAssertFalse(ThreadSelectionIntent.quiet.opensDetailImmediately)
        XCTAssertTrue(ThreadSelectionIntent.restoreFocus.opensDetailImmediately)
    }

    func testOnlyDirectNavigationMayRevealPaneOrRedirectDraft() {
        for intent in [ThreadSelectionIntent.browse, .autoAdvance, .restoreFocus, .quiet] {
            XCTAssertFalse(intent.revealsReadingPane)
            XCTAssertFalse(intent.redirectsDraftToCompose)
        }
        for intent in [ThreadSelectionIntent.click, .explicitOpen] {
            XCTAssertTrue(intent.revealsReadingPane)
            XCTAssertTrue(intent.redirectsDraftToCompose)
        }
    }

    func testMiddleRowAdvancesDown() {
        XCTAssertEqual(SelectionAdvance.neighborId(in: ["a", "b", "c"], removing: "b"), "c")
    }

    func testFirstRowAdvancesDown() {
        XCTAssertEqual(SelectionAdvance.neighborId(in: ["a", "b", "c"], removing: "a"), "b")
    }

    func testLastRowFallsBackUp() {
        XCTAssertEqual(SelectionAdvance.neighborId(in: ["a", "b", "c"], removing: "c"), "b")
    }

    func testOnlyRowReturnsNil() {
        XCTAssertNil(SelectionAdvance.neighborId(in: ["a"], removing: "a"))
    }

    func testMissingIdReturnsNil() {
        XCTAssertNil(SelectionAdvance.neighborId(in: ["a", "b"], removing: "zz"))
        XCTAssertNil(SelectionAdvance.neighborId(in: [], removing: "a"))
    }

    // MARK: - Multi-remove

    func testMultiRemoveAdvancesPastBlock() {
        // Focus on b; remove b and c → land on d (first survivor below).
        XCTAssertEqual(
            SelectionAdvance.neighborId(in: ["a", "b", "c", "d"],
                                        removing: ["b", "c"], focus: "b"),
            "d")
    }

    func testMultiRemoveAtEndFallsBackUp() {
        XCTAssertEqual(
            SelectionAdvance.neighborId(in: ["a", "b", "c"],
                                        removing: ["b", "c"], focus: "c"),
            "a")
    }

    func testMultiRemoveKeepsFocusWhenNotRemoved() {
        XCTAssertEqual(
            SelectionAdvance.neighborId(in: ["a", "b", "c"],
                                        removing: ["a"], focus: "b"),
            "b")
    }

    func testMultiRemoveAllReturnsNil() {
        XCTAssertNil(
            SelectionAdvance.neighborId(in: ["a", "b"],
                                        removing: ["a", "b"], focus: "a"))
    }

    func testMultiRemoveWithNoFocusPicksFirstSurvivor() {
        XCTAssertEqual(
            SelectionAdvance.neighborId(in: ["a", "b", "c"],
                                        removing: ["a"], focus: nil),
            "b")
    }

    func testRemovalDestinationsAdvanceFocusAndDetailIndependently() {
        let result = SelectionAdvance.destinations(
            in: ["a", "b", "c", "d"],
            removing: ["a", "c"],
            selected: "c",
            opened: "a")

        XCTAssertEqual(
            result,
            .init(selectedId: "d", openedId: "b",
                  selectedWasRemoved: true, openedWasRemoved: true))
    }

    func testRemovingOnlyOpenedThreadPreservesListFocus() {
        let result = SelectionAdvance.destinations(
            in: ["a", "b", "c"],
            removing: ["a"],
            selected: "c",
            opened: "a")

        XCTAssertEqual(result.selectedId, "c")
        XCTAssertEqual(result.openedId, "b")
        XCTAssertFalse(result.selectedWasRemoved)
        XCTAssertTrue(result.openedWasRemoved)
    }

    func testRemovingOnlyFocusedThreadPreservesMountedDetail() {
        let result = SelectionAdvance.destinations(
            in: ["a", "b", "c"],
            removing: ["c"],
            selected: "c",
            opened: "a")

        XCTAssertEqual(result.selectedId, "b")
        XCTAssertEqual(result.openedId, "a")
        XCTAssertTrue(result.selectedWasRemoved)
        XCTAssertFalse(result.openedWasRemoved)
    }

    // MARK: - Range

    func testRangeIdsForwardAndBackward() {
        XCTAssertEqual(SelectionAdvance.rangeIds(in: ["a", "b", "c", "d"], from: "b", to: "d"),
                       ["b", "c", "d"])
        XCTAssertEqual(SelectionAdvance.rangeIds(in: ["a", "b", "c", "d"], from: "d", to: "b"),
                       ["b", "c", "d"])
        XCTAssertEqual(SelectionAdvance.rangeIds(in: ["a", "b", "c"], from: "b", to: "b"),
                       ["b"])
    }

    func testRangeIdsMissingReturnsNil() {
        XCTAssertNil(SelectionAdvance.rangeIds(in: ["a", "b"], from: "a", to: "zz"))
        XCTAssertNil(SelectionAdvance.rangeIds(in: [], from: "a", to: "b"))
    }

    // MARK: - Detail open policy

    /// Regression: trash/archive auto-advance must open the neighbor
    /// immediately — the j/k debounce left the reading pane blank and rebuilt
    /// it from scratch (the "delete feels slow" lag).
    func testAdvanceAfterRemovalOpensImmediately() {
        XCTAssertTrue(DetailOpenPolicy.opensImmediately(
            openedThreadId: "b", listedIds: ["a", "c"]))
    }

    func testBrowsingStillListedKeepsDebounce() {
        XCTAssertFalse(DetailOpenPolicy.opensImmediately(
            openedThreadId: "b", listedIds: ["a", "b", "c"]))
    }

    func testNoOpenPaneKeepsDebounce() {
        XCTAssertFalse(DetailOpenPolicy.opensImmediately(
            openedThreadId: nil, listedIds: ["a"]))
    }

    // MARK: - Optimistic leave-list vs stickiness

    /// Regression: under is:unread, opening a thread pins it via keepIds.
    /// Trash must still remove the row so auto-advance can land on the next
    /// conversation — keepIds (and multi-select checks) drop with the row.
    func testLeaveListDropsKeepIdAndChecked() {
        let leave = ThreadListOptimistic.plan(leavesCurrentList: true)
        XCTAssertEqual(leave.effect, .remove)
        XCTAssertEqual(leave.sideEffects, .onRemove)
        XCTAssertTrue(leave.sideEffects.dropKeepId)
        XCTAssertTrue(leave.sideEffects.dropChecked)

        let stay = ThreadListOptimistic.plan(leavesCurrentList: false)
        XCTAssertEqual(stay.effect, .updateInPlace)
        XCTAssertEqual(stay.sideEffects, .none)
    }

    func testUndoInsertionRestoresDescendingListOrder() {
        let now = Date()
        let newest = fixtureThread(id: "c", date: now)
        let restored = fixtureThread(
            id: "b", date: now.addingTimeInterval(-10))
        let oldest = fixtureThread(
            id: "a", date: now.addingTimeInterval(-20))

        XCTAssertEqual(
            ThreadListOptimistic.insertionIndex(
                for: restored, in: [newest, oldest], inboundSort: false),
            1)
    }

    func testUndoInsertionUsesInboundDateForInboxViews() {
        let now = Date()
        let newest = fixtureThread(
            id: "new", date: now,
            inboundDate: now.addingTimeInterval(-10))
        let restored = fixtureThread(
            id: "restore", date: now.addingTimeInterval(100),
            inboundDate: now.addingTimeInterval(-20))
        let oldest = fixtureThread(
            id: "old", date: now.addingTimeInterval(200),
            inboundDate: now.addingTimeInterval(-30))

        XCTAssertEqual(
            ThreadListOptimistic.insertionIndex(
                for: restored, in: [newest, oldest], inboundSort: true),
            1)
    }

    private func fixtureThread(id: String, date: Date,
                               inboundDate: Date? = nil) -> MailThread {
        MailThread(
            id: id, accountId: "a", gmailThreadId: id,
            subject: id, snippet: "", fromDisplay: "F",
            lastDate: date, isUnread: false, isStarred: false,
            inInbox: true, inTrash: false, labelIds: "INBOX",
            snoozeUntil: nil, participants: "F", messageCount: 1,
            hasAttachment: false, reminderAt: nil,
            lastInboundDate: inboundDate)
    }
}
