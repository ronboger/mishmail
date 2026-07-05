import XCTest

final class SnippetExpanderTests: XCTestCase {

    private let ctx = SnippetExpander.Context(
        recipientName: "Alice Smith", recipientEmail: "alice@example.com", date: "Jul 5, 2026")

    func testFirstNameAndName() {
        XCTAssertEqual(SnippetExpander.expand("Hi {{first_name}},", ctx), "Hi Alice,")
        XCTAssertEqual(SnippetExpander.expand("Dear {{name}}", ctx), "Dear Alice Smith")
        XCTAssertEqual(SnippetExpander.expand("({{last_name}})", ctx), "(Smith)")
    }

    func testEmailAndDate() {
        XCTAssertEqual(SnippetExpander.expand("{{email}} on {{date}}", ctx),
                       "alice@example.com on Jul 5, 2026")
    }

    func testCaseInsensitiveAndSpacing() {
        XCTAssertEqual(SnippetExpander.expand("Hi {{ First_Name }}!", ctx), "Hi Alice!")
        XCTAssertEqual(SnippetExpander.expand("Hi {{FIRST_NAME}}", ctx), "Hi Alice")
    }

    func testUnknownPlaceholderLeftIntact() {
        XCTAssertEqual(SnippetExpander.expand("Ref {{ticket_id}}", ctx), "Ref {{ticket_id}}")
    }

    func testEmptyContextYieldsEmptyValues() {
        let empty = SnippetExpander.Context()
        XCTAssertEqual(SnippetExpander.expand("Hi {{first_name}}!", empty), "Hi !")
    }
}
