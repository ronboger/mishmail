import XCTest

@MainActor
final class KeyBindingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "KeyBindingsTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultLookups() {
        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.key(for: .archive), "e")
        XCTAssertEqual(kb.key(for: .trash), "#")
        XCTAssertEqual(kb.command(for: "j"), .next)
        XCTAssertEqual(kb.command(for: "k"), .prev)
        XCTAssertNil(kb.command(for: "x"))
        XCTAssertNil(kb.command(for: "g"))  // reserved, never a command
    }

    func testCatalogCoversAllCommandsWithUniqueDefaults() {
        XCTAssertEqual(Set(KeyBindings.catalog.map(\.command)), Set(ShortcutCommand.allCases))
        let keys = KeyBindings.catalog.map(\.defaultKey)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertTrue(Set(keys).isDisjoint(with: KeyBindings.reservedKeys))
    }

    func testRebindUpdatesBothDirectionsAndPersists() {
        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.rebind(.archive, to: "x"), .ok)
        XCTAssertEqual(kb.key(for: .archive), "x")
        XCTAssertEqual(kb.command(for: "x"), .archive)
        XCTAssertNil(kb.command(for: "e"))  // old key freed
        // A fresh instance over the same defaults sees the override.
        let kb2 = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb2.key(for: .archive), "x")
    }

    func testConflictRefusedAndUnchanged() {
        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.rebind(.snooze, to: "e"), .conflict(.archive))
        XCTAssertEqual(kb.key(for: .snooze), "b")
        XCTAssertEqual(kb.command(for: "e"), .archive)
    }

    func testReservedAndInvalidRejected() {
        let kb = KeyBindings(defaults: defaults)
        guard case .rejected = kb.rebind(.archive, to: "g") else { return XCTFail("g must be rejected") }
        guard case .rejected = kb.rebind(.archive, to: "?") else { return XCTFail("? must be rejected") }
        guard case .rejected = kb.rebind(.archive, to: "ab") else { return XCTFail("multi-char must be rejected") }
        guard case .rejected = kb.rebind(.archive, to: " ") else { return XCTFail("space must be rejected") }
        XCTAssertEqual(kb.key(for: .archive), "e")
    }

    func testAliasKeyTriggersCommandUntilRebound() {
        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.command(for: "b"), .snooze)
        XCTAssertEqual(kb.command(for: "h"), .snooze)  // built-in alias
        // A rebind to the alias key wins over the alias.
        XCTAssertEqual(kb.rebind(.archive, to: "h"), .ok)
        XCTAssertEqual(kb.command(for: "h"), .archive)
    }

    func testRebindToOwnKeyIsOk() {
        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.rebind(.archive, to: "e"), .ok)
        XCTAssertEqual(kb.key(for: .archive), "e")
    }

    func testResetToDefaults() {
        let kb = KeyBindings(defaults: defaults)
        _ = kb.rebind(.archive, to: "x")
        kb.resetToDefaults()
        XCTAssertEqual(kb.key(for: .archive), "e")
        let kb2 = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb2.key(for: .archive), "e")
    }
}
