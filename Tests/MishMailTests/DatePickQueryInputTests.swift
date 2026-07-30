import XCTest

/// Pins the unfocused-keystroke → query path used when the snooze "When?"
/// field has not won first responder yet. Without this routing, bare `s`
/// falls through to the thread list's type-select.
final class DatePickQueryInputTests: XCTestCase {

    func testAppendPrintableCharacter() {
        XCTAssertEqual(
            DatePickQueryInput.handle(query: "", keyCode: 1, characters: "s"),
            .consume("s")
        )
        XCTAssertEqual(
            DatePickQueryInput.handle(query: "s", keyCode: 1, characters: "a"),
            .consume("sa")
        )
    }

    func testDeleteRemovesLastCharacter() {
        XCTAssertEqual(
            DatePickQueryInput.handle(query: "sat", keyCode: 51, characters: nil),
            .consume("sa")
        )
    }

    func testDeleteOnEmptyStillClaims() {
        // Claimed so the event never reaches List type-select / other handlers.
        XCTAssertEqual(
            DatePickQueryInput.handle(query: "", keyCode: 51, characters: nil),
            .consume("")
        )
    }

    func testControlCharactersPassThrough() {
        XCTAssertEqual(
            DatePickQueryInput.handle(query: "s", keyCode: 48, characters: "\t"),
            .passThrough
        )
        XCTAssertEqual(
            DatePickQueryInput.handle(query: "s", keyCode: 36, characters: "\r"),
            .passThrough
        )
    }

    /// Real left-arrow events put U+F702 in charactersIgnoringModifiers, not
    /// nil/empty — that private-use glyph must not enter the query.
    func testFunctionKeyPrivateUsePassThrough() {
        XCTAssertEqual(
            DatePickQueryInput.handle(query: "s", keyCode: 123, characters: "\u{F702}"),
            .passThrough
        )
        XCTAssertEqual(
            DatePickQueryInput.handle(query: "s", keyCode: 124, characters: "\u{F703}"),
            .passThrough
        )
    }

    func testNilOrEmptyCharactersPassThrough() {
        XCTAssertEqual(
            DatePickQueryInput.handle(query: "s", keyCode: 123, characters: nil),
            .passThrough
        )
        XCTAssertEqual(
            DatePickQueryInput.handle(query: "s", keyCode: 123, characters: ""),
            .passThrough
        )
    }

    func testSpaceAppendsForMultiWordQueries() {
        XCTAssertEqual(
            DatePickQueryInput.handle(query: "next", keyCode: 49, characters: " "),
            .consume("next ")
        )
    }
}
