import XCTest

final class UndoToastTests: XCTestCase {

    /// Keyboard triage must not leave a 6s capsule; keep display short.
    func testDisplayDurationIsBrief() {
        XCTAssertEqual(UndoToast.displayDuration, 3.5)
        XCTAssertLessThan(UndoToast.displayDuration, 5,
                          "Undo toast should clear quickly during keyboard triage")
        XCTAssertGreaterThan(UndoToast.displayDuration, 1,
                             "Need a moment to hit z / ⌘Z after a mis-press")
    }

    /// Undo-send keeps its own longer window; the toast chrome duration is
    /// independent so archive/trash can stay snappy.
    func testDisplayDurationIsShorterThanUndoSendWindow() {
        // Undo-send delay is the actual send hold; toast chrome must not
        // match or exceed that by default (regression: both used to be long).
        XCTAssertLessThan(UndoToast.displayDuration, 10)
    }

    /// Animation keys off presence, not identity — nil vs non-nil only.
    func testIsPresentedTracksPresenceOnly() {
        XCTAssertFalse(UndoToast.isPresented(nil as String?))
        XCTAssertTrue(UndoToast.isPresented("Archived" as String?))
        // Distinct stand-ins still present — callers must not re-animate on
        // label/id changes when something is already showing.
        XCTAssertTrue(UndoToast.isPresented("Moved to Trash" as String?))
    }
}

@MainActor
final class UndoShortcutBindingTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "UndoShortcutBindingTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    /// Default `z` and the catalog entry must stay wired so keyboard undo
    /// remains discoverable after rebinds of other keys.
    func testUndoDefaultKeyIsZ() {
        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.key(for: .undo), "z")
        XCTAssertEqual(kb.command(for: "z"), .undo)
    }

    func testUndoRebindIsHonored() {
        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.rebind(.undo, to: "q"), .ok)
        XCTAssertEqual(kb.key(for: .undo), "q")
        XCTAssertEqual(kb.command(for: "q"), .undo)
        XCTAssertNil(kb.command(for: "z"))
    }
}
