import XCTest

final class ComposeAIProposalTests: XCTestCase {
    func testApplyingDraftPreservesExpandedQuote() throws {
        let body = "My notes\n\nOn Tuesday, Jane wrote:\nOriginal email"
        var proposal = try XCTUnwrap(ComposeAIProposal(body: body, range: NSRange(location: 0, length: 8)))
        proposal.text = "Thanks, Jane. I'll review this."
        XCTAssertEqual(proposal.applying(to: body), proposal.text + "\n\nOn Tuesday, Jane wrote:\nOriginal email")
        XCTAssertEqual(proposal.selectedText, "My notes")
    }

    func testTypingDuringGenerationCannotBeOverwritten() throws {
        var proposal = try XCTUnwrap(ComposeAIProposal(body: "Original", range: NSRange(location: 0, length: 8)))
        proposal.text = "Generated draft"
        XCTAssertNil(proposal.applying(to: "Original plus new work"))
        XCTAssertEqual(proposal.applying(to: "Original"), "Generated draft")
    }

    func testSelectionReplacementUsesUTF16AndPreservesSurroundingText() throws {
        let body = "Hi 👋, rewrite this. Thanks."
        let range = (body as NSString).range(of: "rewrite this")
        var proposal = try XCTUnwrap(ComposeAIProposal(body: body, range: range))
        proposal.text = "please review"
        XCTAssertEqual(proposal.applying(to: body), "Hi 👋, please review. Thanks.")
        XCTAssertEqual(proposal.caretUTF16, range.location + (proposal.text as NSString).length)
    }

    func testInvalidAndSplitSurrogateSelectionsAreRejected() {
        XCTAssertNil(ComposeAIProposal(body: "👋", range: NSRange(location: 0, length: 1)))
        XCTAssertNil(ComposeAIProposal(body: "text", range: NSRange(location: NSNotFound, length: 1)))
        XCTAssertNil(ComposeAIProposal(body: "text", range: NSRange(location: 3, length: 9)))
        XCTAssertNil(ComposeAIProposal(body: "text", range: NSRange(location: -1, length: 1)))
    }

    func testEmptyGenerationLeavesBodyIntactAndNewDraftCanBeInserted() throws {
        var proposal = try XCTUnwrap(ComposeAIProposal(body: "", range: NSRange(location: 0, length: 0)))
        XCTAssertNil(proposal.applying(to: ""))
        proposal.text = "  \n"
        XCTAssertNil(proposal.applying(to: ""))
        proposal.text = "Hello!"
        XCTAssertEqual(proposal.applying(to: ""), "Hello!")
    }
}
