import XCTest

final class PaletteCommandsTests: XCTestCase {
    private typealias Thread = PaletteCommands.ThreadState

    private func entries(focused: Thread? = Thread(),
                         checked: [Thread] = [],
                         checkedCount: Int? = nil) -> [PaletteCommands.Entry] {
        var ctx = PaletteCommands.Context()
        ctx.focused = focused
        ctx.checked = checked
        ctx.checkedCount = checkedCount ?? checked.count
        return PaletteCommands.entries(ctx)
    }

    private func entry(_ id: String, in list: [PaletteCommands.Entry],
                       file: StaticString = #filePath, line: UInt = #line) -> PaletteCommands.Entry? {
        let hit = list.first { $0.id == id }
        XCTAssertNotNil(hit, "missing \(id)", file: file, line: line)
        return hit
    }

    func testIdsAreUnique() {
        var ctx = PaletteCommands.Context()
        ctx.focused = Thread()
        ctx.savedViews = [.init(id: 1, name: "Work"), .init(id: 2, name: "Work")]
        let ids = PaletteCommands.entries(ctx).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    // MARK: Thread actions go through the key's own path

    /// The palette row must run the same code as the key (`perform`), which
    /// is what picks the checked set over the focused row. A direct
    /// `archive(thread)` call archived one thread while `e` archived five.
    func testTriageRowsRunTheShortcutCommand() {
        let list = entries()
        XCTAssertEqual(entry("act.archive", in: list)?.action, .perform(.archive))
        XCTAssertEqual(entry("act.trash", in: list)?.action, .perform(.trash))
        XCTAssertEqual(entry("act.star", in: list)?.action, .perform(.toggleStar))
        XCTAssertEqual(entry("act.read", in: list)?.action, .perform(.toggleRead))
        XCTAssertEqual(entry("act.snoozeCustom", in: list)?.action, .perform(.snooze))
        XCTAssertEqual(entry("act.label", in: list)?.action, .perform(.label))
        XCTAssertEqual(entry("act.snooze", in: list)?.action, .snoozeTomorrow)
        XCTAssertEqual(entry("act.archive", in: list)?.shortcut, .archive)
    }

    func testSingleThreadTitlesFollowTheFocusedThread() {
        let plain = entries(focused: Thread())
        XCTAssertEqual(entry("act.archive", in: plain)?.title, "Archive Conversation")
        XCTAssertEqual(entry("act.star", in: plain)?.title, "Star Conversation")
        XCTAssertEqual(entry("act.read", in: plain)?.title, "Mark Unread")
        let flagged = entries(focused: Thread(isStarred: true, isUnread: true))
        XCTAssertEqual(entry("act.star", in: flagged)?.title, "Unstar Conversation")
        XCTAssertEqual(entry("act.read", in: flagged)?.title, "Mark Read")
    }

    func testCheckedThreadsRenameTheRowsToTheSelection() {
        let list = entries(focused: Thread(isStarred: true),
                           checked: [Thread(), Thread(isUnread: true), Thread()])
        XCTAssertEqual(entry("act.archive", in: list)?.title, "Archive 3 Selected Conversations")
        XCTAssertEqual(entry("act.trash", in: list)?.title, "Trash 3 Selected Conversations")
        // Bulk rules, not the focused row: any unstarred → star all; any
        // unread → mark all read.
        XCTAssertEqual(entry("act.star", in: list)?.title, "Star 3 Selected Conversations")
        XCTAssertEqual(entry("act.read", in: list)?.title, "Mark 3 Selected Conversations Read")
        XCTAssertEqual(entry("act.snooze", in: list)?.title, "Snooze 3 Selected Conversations Until Tomorrow")
        XCTAssertEqual(entry("act.label", in: list)?.title, "Label 3 Selected Conversations…")
    }

    func testBulkStarAndReadFlipWhenEveryCheckedThreadAgrees() {
        let list = entries(focused: nil,
                           checked: [Thread(isStarred: true), Thread(isStarred: true)])
        XCTAssertEqual(entry("act.star", in: list)?.title, "Unstar 2 Selected Conversations")
        XCTAssertEqual(entry("act.read", in: list)?.title, "Mark 2 Selected Conversations Unread")
    }

    func testOneCheckedThreadIsSingular() {
        let list = entries(focused: nil, checked: [Thread()])
        XCTAssertEqual(entry("act.archive", in: list)?.title, "Archive 1 Selected Conversation")
    }

    /// `e` works on a multi-select with no focused row, so the palette must
    /// offer the bulk rows too — but not the rows that need one thread.
    func testCheckedWithoutFocusKeepsBulkRowsAndDropsSingleThreadRows() {
        let list = entries(focused: nil, checked: [Thread(), Thread()])
        XCTAssertNotNil(entry("act.archive", in: list))
        XCTAssertNil(list.first { $0.id == "act.reply" })
        XCTAssertNil(list.first { $0.id == "act.copyLink" })
    }

    func testNoThreadNoThreadActions() {
        let list = entries(focused: nil)
        XCTAssertFalse(list.contains { $0.id.hasPrefix("act.") })
        XCTAssertNotNil(entry("compose", in: list))
        XCTAssertEqual(entry("view.Inbox", in: list)?.action, .goTo(.inbox))
    }

    func testSavedViewsFollowBuiltins() {
        var ctx = PaletteCommands.Context()
        ctx.savedViews = [.init(id: 7, name: "Work")]
        let list = PaletteCommands.entries(ctx)
        XCTAssertEqual(list.last?.id, "saved.7")
        XCTAssertEqual(list.last?.title, "Go to Work")
        XCTAssertEqual(list.last?.action, .goToSaved(id: 7, name: "Work"))
    }
}
