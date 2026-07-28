import XCTest

final class GreetingAutocompleteTests: XCTestCase {

    // MARK: - firstName

    func testFirstNameSplitsOnWhitespace() {
        XCTAssertEqual(GreetingAutocomplete.firstName(of: "Alice Smith"), "Alice")
        XCTAssertEqual(GreetingAutocomplete.firstName(of: "  Bob  "), "Bob")
        XCTAssertEqual(GreetingAutocomplete.firstName(of: ""), "")
        XCTAssertEqual(GreetingAutocomplete.firstName(of: "   "), "")
    }

    // MARK: - empty body → default Hi

    func testEmptyBodySuggestsHiName() {
        let s = GreetingAutocomplete.suggestion(
            authoredBody: "", caretUTF16: 0, firstName: "Alice")
        XCTAssertEqual(s?.full, "Hi Alice, ")
        XCTAssertEqual(s?.ghost, "Hi Alice, ")
    }

    func testEmptyFirstNameYieldsNil() {
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "", caretUTF16: 0, firstName: ""))
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "H", caretUTF16: 1, firstName: "  "))
    }

    // MARK: - prefix matching

    func testPartialHiOpener() {
        let s = GreetingAutocomplete.suggestion(
            authoredBody: "H", caretUTF16: 1, firstName: "Alice")
        XCTAssertEqual(s?.full, "Hi Alice, ")
        XCTAssertEqual(s?.ghost, "i Alice, ")
    }

    func testHiWithSpaceSuggestsName() {
        let s = GreetingAutocomplete.suggestion(
            authoredBody: "Hi ", caretUTF16: 3, firstName: "Alice")
        XCTAssertEqual(s?.full, "Hi Alice, ")
        XCTAssertEqual(s?.ghost, "Alice, ")
    }

    func testPartialName() {
        let s = GreetingAutocomplete.suggestion(
            authoredBody: "Hi Al", caretUTF16: 5, firstName: "Alice")
        XCTAssertEqual(s?.full, "Hi Alice, ")
        XCTAssertEqual(s?.ghost, "ice, ")
    }

    func testHeyOpener() {
        let s = GreetingAutocomplete.suggestion(
            authoredBody: "Hey", caretUTF16: 3, firstName: "Alice")
        XCTAssertEqual(s?.full, "Hey Alice, ")
        XCTAssertEqual(s?.ghost, " Alice, ")
    }

    func testHelloOpener() {
        let s = GreetingAutocomplete.suggestion(
            authoredBody: "Hel", caretUTF16: 3, firstName: "Alice")
        XCTAssertEqual(s?.full, "Hello Alice, ")
        XCTAssertEqual(s?.ghost, "lo Alice, ")
    }

    func testCaseInsensitivePrefix() {
        let s = GreetingAutocomplete.suggestion(
            authoredBody: "hi", caretUTF16: 2, firstName: "Alice")
        XCTAssertEqual(s?.full, "Hi Alice, ")
        // Ghost is the template remainder from UTF-16 length 2.
        XCTAssertEqual(s?.ghost, " Alice, ")
    }

    func testCompleteGreetingHidesGhost() {
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "Hi Alice, ", caretUTF16: 10, firstName: "Alice"))
        // Case-insensitive complete also hides.
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "hi alice, ", caretUTF16: 10, firstName: "Alice"))
    }

    // MARK: - gating

    func testCaretNotAtEndHidesGhost() {
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "Hi", caretUTF16: 0, firstName: "Alice"))
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "Hi", caretUTF16: 1, firstName: "Alice"))
    }

    func testCaretPastHeadDoesNotClampIntoGreeting() {
        // Empty authored head + caret inside the quoted tail (UTF-16 offset
        // past head length). Must not clamp to end-of-head and offer Hi Name.
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "", caretUTF16: 5, firstName: "Alice"))
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "Hi", caretUTF16: 40, firstName: "Alice"))
        // Negative caret is also not "at end".
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "", caretUTF16: -1, firstName: "Alice"))
    }

    func testMultilineHeadHidesGhost() {
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "Hi\n", caretUTF16: 3, firstName: "Alice"))
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "Hi Alice, \nMore", caretUTF16: 16, firstName: "Alice"))
    }

    func testNonGreetingPrefixHidesGhost() {
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "Thanks", caretUTF16: 6, firstName: "Alice"))
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "Hi Bob", caretUTF16: 6, firstName: "Alice"))
    }

    func testAmbiguousHPrefersHi() {
        // "H" is a prefix of Hi, Hey, and Hello — Hi wins (opener order).
        let s = GreetingAutocomplete.suggestion(
            authoredBody: "H", caretUTF16: 1, firstName: "Ron")
        XCTAssertEqual(s?.full, "Hi Ron, ")
    }

    func testHePrefersHeyOverHello() {
        let s = GreetingAutocomplete.suggestion(
            authoredBody: "He", caretUTF16: 2, firstName: "Ron")
        XCTAssertEqual(s?.full, "Hey Ron, ")
    }

    // MARK: - apply

    func testApplyingReplacesHeadKeepsTail() {
        let s = GreetingAutocomplete.Suggestion(full: "Hi Alice, ", ghost: "i Alice, ")
        let result = GreetingAutocomplete.applying(
            s, toBody: "H\n\nOn Mon wrote:\nhey", authoredHeadEndUTF16: 1)
        XCTAssertEqual(result.body, "Hi Alice, \n\nOn Mon wrote:\nhey")
        XCTAssertEqual(result.caretUTF16, ("Hi Alice, " as NSString).length)
    }

    func testApplyingOnEmptyBody() {
        let s = GreetingAutocomplete.Suggestion(full: "Hi Alice, ", ghost: "Hi Alice, ")
        let result = GreetingAutocomplete.applying(
            s, toBody: "", authoredHeadEndUTF16: 0)
        XCTAssertEqual(result.body, "Hi Alice, ")
        XCTAssertEqual(result.caretUTF16, 10)
    }
}
