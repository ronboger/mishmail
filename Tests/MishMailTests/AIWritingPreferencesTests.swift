import XCTest

final class AIWritingPreferencesTests: XCTestCase {
    func testPreferencesAreOptionalAndPersistedLocally() {
        let name = "AIWritingPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AIWritingPreferences.instructions(in: defaults), "")
        XCTAssertEqual(AIWritingPreferences.prompt(" \n"), "")
        defaults.set("  Keep it brief.\nUse my booking link.  ", forKey: AIWritingPreferences.storageKey)
        XCTAssertEqual(AIWritingPreferences.instructions(in: defaults), "Keep it brief.\nUse my booking link.")
        XCTAssertTrue(AIWritingPreferences.prompt(AIWritingPreferences.instructions(in: defaults))
            .contains("current request takes precedence"))
    }

    func testPreferencesStayBoundedWithoutSplittingUnicodeCharacters() {
        let raw = String(repeating: "👋", count: AIWritingPreferences.characterLimit + 100)
        let normalized = AIWritingPreferences.normalized(raw)
        XCTAssertEqual(normalized.count, AIWritingPreferences.characterLimit)
        XCTAssertEqual(normalized.last, "👋")
    }
}
