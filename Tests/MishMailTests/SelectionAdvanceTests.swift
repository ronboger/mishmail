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

    func testSinglePressOpensWithNoSettle() {
        // Notion Mail–style: a deliberate j/k or ↑/↓ opens immediately.
        XCTAssertEqual(
            DetailOpenPolicy.settleNanoseconds(isKeyRepeat: false), 0)
        XCTAssertEqual(DetailOpenPolicy.singlePressSettleNanoseconds, 0)
    }

    func testKeyRepeatSettleCoalescesHeldKeys() {
        // System key-repeat is ~30–50 ms; settle must outlast a stretched
        // main-thread gap so intermediate opens do not fire while holding ↓.
        let settle = DetailOpenPolicy.settleNanoseconds(isKeyRepeat: true)
        XCTAssertEqual(settle, DetailOpenPolicy.keyRepeatSettleNanoseconds)
        XCTAssertGreaterThanOrEqual(settle, 30_000_000)
        XCTAssertLessThanOrEqual(settle, 100_000_000)
    }

    // MARK: - Thread list navigation (focus only)

    func testMoveDownFromNilSelectsFirst() {
        let order = ["a", "b", "c"]
        let map = ThreadListNavigation.indexMap(for: order)
        XCTAssertEqual(
            ThreadListNavigation.move(selected: nil, delta: 1, order: order, indexById: map),
            "a")
    }

    func testMoveUpFromNilSelectsFirst() {
        let order = ["a", "b", "c"]
        XCTAssertEqual(
            ThreadListNavigation.move(selected: nil, delta: -1, order: order),
            "a")
    }

    func testMoveClampsAtEnds() {
        let order = ["a", "b", "c"]
        let map = ThreadListNavigation.indexMap(for: order)
        XCTAssertEqual(
            ThreadListNavigation.move(selected: "c", delta: 1, order: order, indexById: map),
            "c")
        XCTAssertEqual(
            ThreadListNavigation.move(selected: "a", delta: -1, order: order, indexById: map),
            "a")
    }

    func testMoveUsesIndexMapWithoutLinearScan() {
        let order = (0..<500).map(String.init)
        let map = ThreadListNavigation.indexMap(for: order)
        XCTAssertEqual(map["250"], 250)
        XCTAssertEqual(
            ThreadListNavigation.move(selected: "250", delta: 1, order: order, indexById: map),
            "251")
        XCTAssertEqual(
            ThreadListNavigation.move(selected: "250", delta: -3, order: order, indexById: map),
            "247")
    }

    func testMoveEmptyOrderReturnsNil() {
        XCTAssertNil(ThreadListNavigation.move(selected: "a", delta: 1, order: []))
    }

    func testMoveMissingSelectionTreatsAsBeforeFirstOnDown() {
        let order = ["a", "b", "c"]
        XCTAssertEqual(
            ThreadListNavigation.move(selected: "zz", delta: 1, order: order),
            "a")
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

    /// Regression: snooze must leave the inbox immediately (like archive/trash)
    /// so auto-advance can open the neighbor in the same update. If the row
    /// only drops after the ~140 ms reconciliation, the handoff feels laggy.
    func testSnoozeFromInboxLeavesListLikeArchive() {
        let now = Date()
        let until = now.addingTimeInterval(3600)
        // After snooze: inInbox = false, snoozeUntil set.
        XCTAssertTrue(ThreadListOptimistic.leavesInboxList(
            inInbox: false, inSpam: false, snoozeUntil: until,
            showArchived: false, now: now))
        // After archive: inInbox = false, no snooze.
        XCTAssertTrue(ThreadListOptimistic.leavesInboxList(
            inInbox: false, inSpam: false, snoozeUntil: nil,
            showArchived: false, now: now))
        // Still in inbox and not snoozed → stay.
        XCTAssertFalse(ThreadListOptimistic.leavesInboxList(
            inInbox: true, inSpam: false, snoozeUntil: nil,
            showArchived: false, now: now))
        // showArchived keeps both archive and snooze visible until reload.
        XCTAssertFalse(ThreadListOptimistic.leavesInboxList(
            inInbox: false, inSpam: false, snoozeUntil: until,
            showArchived: true, now: now))
        // Plan must remove so keepIds cannot pin the row under is:unread.
        let plan = ThreadListOptimistic.plan(leavesCurrentList: true)
        XCTAssertEqual(plan.effect, .remove)
        XCTAssertTrue(plan.sideEffects.dropKeepId)
    }

    /// Snooze auto-advance must open the neighbor immediately — same policy
    /// that fixed the "delete feels slow" lag for trash/archive.
    func testSnoozeAdvanceOpensNeighborImmediately() {
        XCTAssertTrue(DetailOpenPolicy.opensImmediately(
            openedThreadId: "snoozed-id", listedIds: ["a", "c"]))
        XCTAssertEqual(
            SelectionAdvance.neighborId(in: ["a", "snoozed-id", "c"],
                                        removing: "snoozed-id"),
            "c")
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

    /// Attachment recovery re-derives hasAttachment but only the in-memory
    /// list row drives the paperclip; field-only patch by id.
    func testPatchingHasAttachmentUpdatesPaperclipFlagInPlace() {
        var stale = fixtureThread(id: "t1", date: Date(), hasAttachment: false)
        stale.isStarred = true  // concurrent optimistic state must survive
        let other = fixtureThread(id: "t2", date: Date(), hasAttachment: true)
        let updated = ThreadListOptimistic.patchingHasAttachment(
            true, threadId: "t1", in: [stale, other])
        XCTAssertEqual(updated?.map(\.id), ["t1", "t2"])
        XCTAssertEqual(updated?[0].hasAttachment, true)
        XCTAssertEqual(updated?[0].isStarred, true, "must not clobber other fields")
        XCTAssertEqual(updated?[1].hasAttachment, true)
        // No-op when flag already matches — avoid redundant Observation publishes.
        XCTAssertNil(ThreadListOptimistic.patchingHasAttachment(
            true, threadId: "t2", in: [stale, other]))
        // Unknown id: no insert into the current window.
        XCTAssertNil(ThreadListOptimistic.patchingHasAttachment(
            true, threadId: "absent", in: [stale, other]))
    }

    /// Regression: Undo must not flash a restored row into the wrong list.
    /// Active-account filter and committed search both scope ownership;
    /// reconciliation reloads the correct context (~140ms).
    func testUndoReinsertSkipsWrongAccountAndActiveSearch() {
        // Unified inbox (nil active) always owns any account.
        XCTAssertTrue(ThreadListOptimistic.shouldReinsertAbsent(
            threadAccountId: "a@x.com",
            activeAccountId: nil,
            committedSearchActive: false))
        // Matching account filter: insert OK.
        XCTAssertTrue(ThreadListOptimistic.shouldReinsertAbsent(
            threadAccountId: "a@x.com",
            activeAccountId: "a@x.com",
            committedSearchActive: false))
        // Wrong account: skip (would flash into account B's list).
        XCTAssertFalse(ThreadListOptimistic.shouldReinsertAbsent(
            threadAccountId: "a@x.com",
            activeAccountId: "b@x.com",
            committedSearchActive: false))
        // Committed search: skip even for matching / unified account.
        XCTAssertFalse(ThreadListOptimistic.shouldReinsertAbsent(
            threadAccountId: "a@x.com",
            activeAccountId: "a@x.com",
            committedSearchActive: true))
        XCTAssertFalse(ThreadListOptimistic.shouldReinsertAbsent(
            threadAccountId: "a@x.com",
            activeAccountId: nil,
            committedSearchActive: true))
    }

    private func fixtureThread(id: String, date: Date,
                               inboundDate: Date? = nil,
                               hasAttachment: Bool = false) -> MailThread {
        MailThread(
            id: id, accountId: "a", gmailThreadId: id,
            subject: id, snippet: "", fromDisplay: "F",
            lastDate: date, isUnread: false, isStarred: false,
            inInbox: true, inTrash: false, labelIds: "INBOX",
            snoozeUntil: nil, participants: "F", messageCount: 1,
            hasAttachment: hasAttachment, reminderAt: nil,
            lastInboundDate: inboundDate)
    }
}
