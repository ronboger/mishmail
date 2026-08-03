import XCTest

final class PrioritySectionAdvanceTests: XCTestCase {
    private func thread(_ id: String, starred: Bool = true,
                        labels: String = "INBOX") -> MailThread {
        MailThread(id: "a@x.com:\(id)", accountId: "a@x.com", gmailThreadId: id,
                   subject: "s", snippet: "sn", fromDisplay: "F",
                   lastDate: Date(timeIntervalSince1970: 1000),
                   isUnread: false, isStarred: starred, inInbox: true,
                   inTrash: false, labelIds: labels, snoozeUntil: nil,
                   participants: "F", messageCount: 1, hasAttachment: false,
                   reminderAt: nil)
    }

    private var a: MailThread { thread("a") }
    private var b: MailThread { thread("b") }
    private var c: MailThread { thread("c") }

    private var sectionOrder: [String] {
        [a.id, b.id, c.id]
    }

    private var sectionIds: Set<String> { Set(sectionOrder) }

    // MARK: - destinations within section order

    func testUnstarMidSectionAdvancesToNextInSection() {
        // Mid priority row unstar → next below in section, not full list.
        let dest = PrioritySectionAdvance.destinations(
            sectionOrder: sectionOrder,
            leaving: [b.id],
            selected: b.id,
            opened: b.id)
        XCTAssertEqual(dest.selectedId, c.id)
        XCTAssertEqual(dest.openedId, c.id)
        XCTAssertTrue(dest.selectedWasRemoved)
        XCTAssertTrue(dest.openedWasRemoved)
    }

    func testUnstarLastSectionRowFallsBackUpward() {
        let dest = PrioritySectionAdvance.destinations(
            sectionOrder: sectionOrder,
            leaving: [c.id],
            selected: c.id,
            opened: c.id)
        XCTAssertEqual(dest.selectedId, b.id)
        XCTAssertEqual(dest.openedId, b.id)
    }

    func testUnstarOnlySectionRowYieldsNilDestinations() {
        let only = a.id
        let dest = PrioritySectionAdvance.destinations(
            sectionOrder: [only],
            leaving: [only],
            selected: only,
            opened: only)
        XCTAssertNil(dest.selectedId)
        XCTAssertNil(dest.openedId)
        XCTAssertTrue(dest.selectedWasRemoved)
        XCTAssertTrue(dest.openedWasRemoved)
    }

    // MARK: - idsLeavingSection

    func testVIPWithAlwaysPinsDoesNotLeaveSection() {
        let vip = thread("vip", starred: true)
        let leaving = PrioritySectionAdvance.idsLeavingSection(
            targets: [vip],
            sectionIds: [vip.id],
            mode: .starred,
            vipThreadIds: [vip.id],
            vipAlwaysPins: true)
        XCTAssertTrue(leaving.isEmpty)
    }

    func testImportantLabeledDoesNotLeaveUnderStarredImportant() {
        let important = thread("imp", starred: true, labels: "INBOX IMPORTANT")
        let leaving = PrioritySectionAdvance.idsLeavingSection(
            targets: [important],
            sectionIds: [important.id],
            mode: .starredImportant,
            vipThreadIds: [],
            vipAlwaysPins: true)
        XCTAssertTrue(leaving.isEmpty)
    }

    func testModeOffYieldsEmptyLeaving() {
        let leaving = PrioritySectionAdvance.idsLeavingSection(
            targets: [a],
            sectionIds: [a.id],
            mode: .off,
            vipThreadIds: [],
            vipAlwaysPins: true)
        XCTAssertTrue(leaving.isEmpty)
    }

    func testTargetNotInSectionIdsDoesNotLeave() {
        // Unstar in the rest of the list (date groups) — not a Priority leave.
        let outside = thread("rest")
        let leaving = PrioritySectionAdvance.idsLeavingSection(
            targets: [outside],
            sectionIds: sectionIds,
            mode: .starred,
            vipThreadIds: [],
            vipAlwaysPins: true)
        XCTAssertTrue(leaving.isEmpty)
    }

    func testPlainStarredTargetLeavesSection() {
        let leaving = PrioritySectionAdvance.idsLeavingSection(
            targets: [b],
            sectionIds: sectionIds,
            mode: .starred,
            vipThreadIds: [],
            vipAlwaysPins: true)
        XCTAssertEqual(leaving, [b.id])
    }

    // MARK: - destinations independence (mirrors SelectionAdvance)

    func testDestinationsLeavesUnremovedSelectedUntouched() {
        let dest = PrioritySectionAdvance.destinations(
            sectionOrder: sectionOrder,
            leaving: [a.id],
            selected: c.id,
            opened: a.id)
        XCTAssertEqual(dest.selectedId, c.id)
        XCTAssertFalse(dest.selectedWasRemoved)
        XCTAssertEqual(dest.openedId, b.id)
        XCTAssertTrue(dest.openedWasRemoved)
    }

    func testDestinationsAdvancesOpenedIndependentlyOfSelected() {
        let dest = PrioritySectionAdvance.destinations(
            sectionOrder: sectionOrder,
            leaving: [c.id],
            selected: a.id,
            opened: c.id)
        XCTAssertEqual(dest.selectedId, a.id)
        XCTAssertFalse(dest.selectedWasRemoved)
        XCTAssertEqual(dest.openedId, b.id)
        XCTAssertTrue(dest.openedWasRemoved)
    }
}
