import AppKit
import XCTest

final class ComposeSpellCheckTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ComposeSpellCheckTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testMissingKeysDefaultToOn() {
        XCTAssertEqual(ComposeSpellCheck.options(from: defaults),
                       .init(spelling: true, grammar: true))
    }

    func testStoredValuesAreRead() {
        defaults.set(false, forKey: ComposeSpellCheck.grammarKey)
        XCTAssertEqual(ComposeSpellCheck.options(from: defaults),
                       .init(spelling: true, grammar: false))
        defaults.set(false, forKey: ComposeSpellCheck.spellingKey)
        XCTAssertEqual(ComposeSpellCheck.options(from: defaults),
                       .init(spelling: false, grammar: false))
    }

    func testApplyTurnsBothChecksOn() {
        let view = NSTextView()
        ComposeSpellCheck.apply(.init(spelling: true, grammar: true), to: view)
        XCTAssertTrue(view.isContinuousSpellCheckingEnabled)
        XCTAssertTrue(view.isGrammarCheckingEnabled)
    }

    func testGrammarFollowsSpellingOff() {
        let view = NSTextView()
        ComposeSpellCheck.apply(.init(spelling: true, grammar: true), to: view)
        ComposeSpellCheck.apply(.init(spelling: false, grammar: true), to: view)
        XCTAssertFalse(view.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(view.isGrammarCheckingEnabled)
    }

    func testGrammarOffKeepsSpelling() {
        let view = NSTextView()
        ComposeSpellCheck.apply(.init(spelling: true, grammar: false), to: view)
        XCTAssertTrue(view.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(view.isGrammarCheckingEnabled)
    }
}
