import XCTest

/// Regression: multi-select snooze (`h` / `b` over checked rows) used to snooze
/// only the last-focused thread. `perform(.snooze)` set `snoozingThread` without
/// ever looking at `checkedThreadIds`, unlike every sibling bulk action
/// (archive, trash, star, read/unread, spam). See `MailStore.snoozeChecked`.
///
/// The hostless unit-test target does not compile `MailStore.swift` (AppKit +
/// `@MainActor`), so the routing, ordering, and mutation rules below are
/// mirrors of that production code — same convention as
/// `StarUnstarStickinessTests`. Update these copies when `snoozeChecked`,
/// `checkedThreadsInOrder`, or `dismissSnoozePicker` change. The undo label and
/// date formatting are NOT mirrored: `SnoozeDateParser` is in the target, so
/// those assertions run against production code.
final class BulkSnoozeTests: XCTestCase {

    // MARK: - Fixtures

    private func makeThread(id: String, inInbox: Bool = true,
                            snoozeUntil: Date? = nil) -> MailThread {
        MailThread(
            id: "a:\(id)", accountId: "a@x.com", gmailThreadId: id,
            subject: id, snippet: "sn", fromDisplay: "F",
            lastDate: Date(), isUnread: false, isStarred: false,
            inInbox: inInbox, inTrash: false,
            labelIds: "INBOX", snoozeUntil: snoozeUntil, participants: "F",
            messageCount: 1, hasAttachment: false, reminderAt: nil)
    }

    /// Fixed pick date so label assertions do not depend on "today".
    private let pick = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Routing (the actual regression)

    private enum SnoozeRoute: Equatable { case bulk, single(String), none }

    /// Mirrors `MailStore.perform(.snooze)`:
    ///     if !checkedThreadIds.isEmpty { snoozingChecked = true }
    ///     else if let t = selectedThread { snoozingThread = t }
    private func route(checked: Set<String>, selected: String?) -> SnoozeRoute {
        if !checked.isEmpty { return .bulk }
        if let selected { return .single(selected) }
        return .none
    }

    func testCheckedSelectionRoutesToBulkSnooze() {
        XCTAssertEqual(route(checked: ["a:1", "a:2"], selected: "a:2"), .bulk,
                       "multi-select must snooze the whole check set, not the focused row")
    }

    func testSingleCheckedRowStillRoutesToBulk() {
        // One checked row is still the bulk path — it clears the check set and
        // uses the singular undo label, which the single-thread path does not.
        XCTAssertEqual(route(checked: ["a:1"], selected: "a:9"), .bulk)
    }

    func testNoCheckedRowsFallsBackToFocusedThread() {
        XCTAssertEqual(route(checked: [], selected: "a:7"), .single("a:7"))
    }

    func testNoCheckedRowsAndNoFocusOpensNothing() {
        XCTAssertEqual(route(checked: [], selected: nil), .none)
    }

    // MARK: - Target set (mirrors checkedThreadsInOrder)

    private func targets(order: [String], checked: Set<String>,
                         threads: [MailThread]) -> [MailThread] {
        let byId = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        return order.compactMap { id in
            guard checked.contains(id) else { return nil }
            return byId[id]
        }
    }

    func testTargetsFollowListOrderNotCheckOrder() {
        let threads = ["a:1", "a:2", "a:3"].map { makeThread(id: String($0.dropFirst(2))) }
        let got = targets(order: ["a:1", "a:2", "a:3"],
                          checked: ["a:3", "a:1"], threads: threads)
        XCTAssertEqual(got.map(\.id), ["a:1", "a:3"],
                       "undo and focus advance depend on display order")
    }

    func testCheckedIdsWithNoLoadedRowAreDropped() {
        // Checked ids outlive their rows when the list is refiltered.
        let threads = [makeThread(id: "1")]
        let got = targets(order: ["a:1", "a:2"],
                          checked: ["a:1", "a:2"], threads: threads)
        XCTAssertEqual(got.map(\.id), ["a:1"])
    }

    // MARK: - Mutation applied to every target

    /// Mirrors the `local:` closure of `snoozeChecked` and of its undo.
    private func applySnooze(_ threads: [MailThread], until date: Date) -> [MailThread] {
        threads.map { var t = $0; t.snoozeUntil = date; t.inInbox = false; return t }
    }

    private func applyUnsnooze(_ threads: [MailThread]) -> [MailThread] {
        threads.map { var t = $0; t.snoozeUntil = nil; t.inInbox = true; return t }
    }

    func testEverySelectedThreadLeavesTheInboxSnoozed() {
        let before = ["1", "2", "3"].map { makeThread(id: $0) }
        let after = applySnooze(before, until: pick)

        XCTAssertEqual(after.count, 3)
        for t in after {
            XCTAssertEqual(t.snoozeUntil, pick, "\(t.id) kept its old snooze date")
            XCTAssertFalse(t.inInbox, "\(t.id) stayed in the inbox")
        }
    }

    func testUndoRestoresEverySelectedThread() {
        let snoozed = applySnooze(["1", "2", "3"].map { makeThread(id: $0) }, until: pick)
        let restored = applyUnsnooze(snoozed)

        for t in restored {
            XCTAssertNil(t.snoozeUntil, "\(t.id) stayed snoozed after undo")
            XCTAssertTrue(t.inInbox, "\(t.id) did not return to the inbox")
        }
    }

    // MARK: - Undo label (production SnoozeDateParser)

    /// Mirrors the label branch of `snoozeChecked`.
    private func undoLabel(count: Int, date: Date) -> String {
        count == 1
            ? SnoozeDateParser.undoLabel(until: date)
            : "Snoozed \(count) conversations until \(SnoozeDateParser.format(date))"
    }

    func testSingleTargetUsesTheSingularUndoLabel() {
        XCTAssertEqual(undoLabel(count: 1, date: pick),
                       SnoozeDateParser.undoLabel(until: pick))
    }

    func testManyTargetsCountThemInTheUndoLabel() {
        let label = undoLabel(count: 4, date: pick)
        XCTAssertEqual(label, "Snoozed 4 conversations until \(SnoozeDateParser.format(pick))")
        XCTAssertTrue(label.contains("4 conversations"),
                      "undo must say how many threads it will bring back")
    }

    // MARK: - Picker teardown (mirrors dismissSnoozePicker)

    private struct Picker { var snoozingThread: String?; var snoozingChecked = false }

    @discardableResult
    private func dismiss(_ p: inout Picker) -> Bool {
        guard p.snoozingThread != nil || p.snoozingChecked else { return false }
        p.snoozingThread = nil
        p.snoozingChecked = false
        return true
    }

    func testDismissClosesTheBulkPickerToo() {
        var p = Picker(snoozingThread: nil, snoozingChecked: true)
        XCTAssertTrue(dismiss(&p), "guard used to return early on the bulk overlay")
        XCTAssertFalse(p.snoozingChecked)
    }

    func testDismissIsANoOpWhenNoPickerIsOpen() {
        var p = Picker(snoozingThread: nil, snoozingChecked: false)
        XCTAssertFalse(dismiss(&p))
    }

    func testPickAgainstAStaleCheckSetStillClosesThePicker() {
        // `snoozeChecked` dismisses *before* the empty-targets guard, so a pick
        // whose rows are all gone closes the sheet instead of looking stuck.
        var p = Picker(snoozingThread: nil, snoozingChecked: true)
        dismiss(&p)
        let stale = targets(order: [], checked: ["a:1"], threads: [])
        XCTAssertTrue(stale.isEmpty)
        XCTAssertFalse(p.snoozingChecked, "sheet must close even on a no-op pick")
    }

    // MARK: - Key-monitor passthrough

    /// Mirrors ContentView's monitor guard: while either snooze overlay is up,
    /// keys belong to the date field, not to the global shortcuts.
    private func passesKeysThrough(snoozingThread: String?, snoozingChecked: Bool) -> Bool {
        snoozingThread != nil || snoozingChecked
    }

    func testBulkPickerSwallowsGlobalShortcuts() {
        XCTAssertTrue(passesKeysThrough(snoozingThread: nil, snoozingChecked: true))
        XCTAssertTrue(passesKeysThrough(snoozingThread: "a:1", snoozingChecked: false))
        XCTAssertFalse(passesKeysThrough(snoozingThread: nil, snoozingChecked: false))
    }
}
