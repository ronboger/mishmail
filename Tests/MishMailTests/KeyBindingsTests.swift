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
        XCTAssertEqual(kb.key(for: .markSpam), "!")
        XCTAssertEqual(kb.command(for: "j"), .next)
        XCTAssertEqual(kb.command(for: "k"), .prev)
        XCTAssertEqual(kb.command(for: "!"), .markSpam)
        XCTAssertEqual(kb.command(for: "x"), .toggleCheck)
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
        // "q" is free (x is the default multi-select toggle).
        XCTAssertEqual(kb.rebind(.archive, to: "q"), .ok)
        XCTAssertEqual(kb.key(for: .archive), "q")
        XCTAssertEqual(kb.command(for: "q"), .archive)
        XCTAssertNil(kb.command(for: "e"))  // old key freed
        // A fresh instance over the same defaults sees the override.
        let kb2 = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb2.key(for: .archive), "q")
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
        _ = kb.rebind(.archive, to: "q")
        kb.resetToDefaults()
        XCTAssertEqual(kb.key(for: .archive), "e")
        let kb2 = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb2.key(for: .archive), "e")
    }

    /// Ship-blocker: a pre-existing archive→x rebind must not be stolen by the
    /// new toggleCheck default of x. Overrides win at lookup; migration parks
    /// the shadowed default-only command on a free key so Settings stays honest.
    func testExistingOverrideToXWinsOverNewToggleCheckDefault() {
        // Simulate prefs written before toggleCheck existed.
        let raw = ["archive": "x"]
        let data = try! JSONEncoder().encode(raw)
        defaults.set(data, forKey: "keyBindings")

        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.command(for: "x"), .archive)
        XCTAssertEqual(kb.key(for: .archive), "x")
        // toggleCheck was parked off x so it remains reachable and doesn't
        // dual-display as x in Settings.
        XCTAssertNotEqual(kb.key(for: .toggleCheck), "x")
        XCTAssertEqual(kb.command(for: kb.key(for: .toggleCheck)), .toggleCheck)
        // Persist migration for the next launch.
        let kb2 = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb2.command(for: "x"), .archive)
        XCTAssertEqual(kb2.key(for: .toggleCheck), kb.key(for: .toggleCheck))
    }

    func testOverrideWinsOverDefaultAtLookupWithoutMigrationNeed() {
        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.rebind(.trash, to: "q"), .ok)
        // Default snooze is still b; q is only trash.
        XCTAssertEqual(kb.command(for: "q"), .trash)
        XCTAssertEqual(kb.command(for: "b"), .snooze)
    }
}
