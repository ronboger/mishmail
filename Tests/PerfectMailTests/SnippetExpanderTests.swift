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

    // MARK: - Single-brace (Notion Mail) syntax

    func testSingleBraceVariables() {
        XCTAssertEqual(SnippetExpander.expand("Hi {first_name},", ctx), "Hi Alice,")
        XCTAssertEqual(SnippetExpander.expand("Dear {name}", ctx), "Dear Alice Smith")
        XCTAssertEqual(SnippetExpander.expand("{email} on { date }", ctx),
                       "alice@example.com on Jul 5, 2026")
    }

    func testSingleBraceUnknownLeftIntact() {
        XCTAssertEqual(SnippetExpander.expand("Ref {ticket_id}", ctx), "Ref {ticket_id}")
    }

    func testMixedBraceStyles() {
        XCTAssertEqual(SnippetExpander.expand("{first_name} / {{last_name}}", ctx),
                       "Alice / Smith")
    }

    // MARK: - Sender and bcc-person variables

    private var fullCtx: SnippetExpander.Context {
        var c = ctx
        c.myName = "Ron Boger"
        c.bccName = "Carol Introducer"
        c.bccEmail = "carol@intro.com"
        return c
    }

    func testMyNameVariables() {
        XCTAssertEqual(SnippetExpander.expand("Best,\n{my_first_name}", fullCtx),
                       "Best,\nRon")
        XCTAssertEqual(SnippetExpander.expand("— {{my_name}}", fullCtx), "— Ron Boger")
    }

    func testBccPersonVariables() {
        XCTAssertEqual(
            SnippetExpander.expand(
                "Thanks {bcc_first_name} for the intro! Hi {first_name},", fullCtx),
            "Thanks Carol for the intro! Hi Alice,")
        XCTAssertEqual(SnippetExpander.expand("{bcc_name} <{bcc_email}>", fullCtx),
                       "Carol Introducer <carol@intro.com>")
    }
}
