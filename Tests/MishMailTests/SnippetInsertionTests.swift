import XCTest

final class SnippetInsertionTests: XCTestCase {

    // MARK: - Move-to-bcc recipient shuffling

    func testMoveToBccMovesToAndPromotesCc() {
        let r = SnippetInsertion.moveToBcc(
            to: ["introducer@x.com"], cc: ["newperson@y.com"], bcc: [])
        XCTAssertEqual(r.to, ["newperson@y.com"])
        XCTAssertEqual(r.cc, [])
        XCTAssertEqual(r.bcc, ["introducer@x.com"])
    }

    func testMoveToBccKeepsExistingBcc() {
        let r = SnippetInsertion.moveToBcc(
            to: ["a@x.com"], cc: ["b@y.com"], bcc: ["c@z.com"])
        XCTAssertEqual(r.bcc, ["c@z.com", "a@x.com"])
    }

    func testMoveToBccWithEmptyToStillPromotesCc() {
        let r = SnippetInsertion.moveToBcc(to: [], cc: ["b@y.com"], bcc: [])
        XCTAssertEqual(r.to, ["b@y.com"])
        XCTAssertEqual(r.cc, [])
        XCTAssertEqual(r.bcc, [])
    }

    func testMoveToBccDedupesCaseInsensitively() {
        let r = SnippetInsertion.moveToBcc(
            to: ["A@x.com"], cc: ["a@x.com", "b@y.com"], bcc: ["A@X.com"])
        XCTAssertEqual(r.to, ["b@y.com"])
        XCTAssertEqual(r.bcc, ["A@X.com"])   // already there; not added twice
    }

    func testMoveToBccNoRecipientsIsNoop() {
        let r = SnippetInsertion.moveToBcc(to: [], cc: [], bcc: [])
        XCTAssertEqual(r.to, [])
        XCTAssertEqual(r.cc, [])
        XCTAssertEqual(r.bcc, [])
    }

    // MARK: - Slash-trigger detection

    func testSlashAtStartOfTextTriggers() {
        let t = SnippetInsertion.slashToken(in: "/")
        XCTAssertEqual(t?.query, "")
    }

    func testSlashQueryIsExtracted() {
        let t = SnippetInsertion.slashToken(in: "/intro find")
        XCTAssertEqual(t?.query, "intro find")
    }

    func testSlashAfterNewlineTriggers() {
        XCTAssertEqual(SnippetInsertion.slashToken(in: "Hi Bob,\n/fol")?.query, "fol")
    }

    func testSlashAfterSpaceTriggers() {
        XCTAssertEqual(SnippetInsertion.slashToken(in: "see: /zoom")?.query, "zoom")
    }

    func testSlashInsideWordDoesNotTrigger() {
        XCTAssertNil(SnippetInsertion.slashToken(in: "a/b"))
        XCTAssertNil(SnippetInsertion.slashToken(in: "https://example.com/foo"))
    }

    func testNoSlashNoTrigger() {
        XCTAssertNil(SnippetInsertion.slashToken(in: "hello"))
        XCTAssertNil(SnippetInsertion.slashToken(in: ""))
    }

    func testQueryStopsAtNewline() {
        // A newline after the slash token ends the trigger — the user moved on.
        XCTAssertNil(SnippetInsertion.slashToken(in: "/intro\nmore text"))
    }

    func testReplacingTokenRemovesSlashAndQuery() {
        let text = "Hi Bob,\n/intro"
        guard let t = SnippetInsertion.slashToken(in: text) else {
            return XCTFail("expected a slash token")
        }
        var replaced = text
        replaced.replaceSubrange(t.range, with: "EXPANDED")
        XCTAssertEqual(replaced, "Hi Bob,\nEXPANDED")
    }
}
