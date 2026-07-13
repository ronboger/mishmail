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
        let t = SnippetInsertion.slashToken(in: "/intro")
        XCTAssertEqual(t?.query, "intro")
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

    func testQueryStopsAtSpace() {
        // Space after the slash token ends the trigger — dismiss the picker;
        // the typed `/query ` remains as literal body text.
        XCTAssertNil(SnippetInsertion.slashToken(in: "/intro find"))
        XCTAssertNil(SnippetInsertion.slashToken(in: "/ "))
        XCTAssertNil(SnippetInsertion.slashToken(in: "/intro "))
        let mid = "prefix /zoom trailing"
        let afterSpace = mid.range(of: "/zoom ")!.upperBound
        XCTAssertNil(SnippetInsertion.slashToken(in: mid, atCaret: afterSpace))
    }

    func testQueryStopsAtTab() {
        XCTAssertNil(SnippetInsertion.slashToken(in: "/intro\t"))
    }

    func testQueryStopsAtNBSP() {
        // U+00A0 is Character.isWhitespace — dismisses like a regular space.
        XCTAssertNil(SnippetInsertion.slashToken(in: "/intro\u{00A0}"))
    }

    func testBackspaceAfterSpaceReopensPicker() {
        // Unlike Esc (slashDismissed), space ends the token itself — so
        // deleting the space restores a live `/query` token.
        XCTAssertNil(SnippetInsertion.slashToken(in: "/intro "))
        XCTAssertEqual(SnippetInsertion.slashToken(in: "/intro")?.query, "intro")
    }

    func testCaretBeforeTrailingSpaceKeepsTokenLive() {
        // Caret between query and trailing space: only slash→caret is the
        // query, so the token stays live even though a space sits after.
        let text = "/intro "
        let afterIntro = text.range(of: "/intro")!.upperBound
        XCTAssertEqual(SnippetInsertion.slashToken(in: text, atCaret: afterIntro)?.query, "intro")
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

    // MARK: - Caret-aware mid-message / multi-snippet

    func testSlashMidMessageAtCaret() {
        let text = "Hi Bob,\n/cal\nSee you soon."
        let afterCal = text.range(of: "/cal")!.upperBound
        let t = SnippetInsertion.slashToken(in: text, atCaret: afterCal)
        XCTAssertEqual(t?.query, "cal")
        // Replacement must leave the trailing paragraph alone.
        var replaced = text
        replaced.replaceSubrange(t!.range, with: "Let's find a time.")
        XCTAssertEqual(replaced, "Hi Bob,\nLet's find a time.\nSee you soon.")
    }

    func testSlashAfterPriorSnippetAtCaret() {
        let text = "Thanks for the intro!\n\n/intro"
        let t = SnippetInsertion.slashToken(in: text, atCaret: text.endIndex)
        XCTAssertEqual(t?.query, "intro")
    }

    func testCaretBeforeTrailingTextDoesNotSwallowIt() {
        let text = "prefix /zoom trailing"
        let afterZoom = text.range(of: "/zoom")!.upperBound
        let t = SnippetInsertion.slashToken(in: text, atCaret: afterZoom)
        XCTAssertEqual(t?.query, "zoom")
        var replaced = text
        replaced.replaceSubrange(t!.range, with: "LINK")
        XCTAssertEqual(replaced, "prefix LINK trailing")
    }

    func testCaretNotOnSlashTokenYieldsNilWhenPastNewline() {
        let text = "/intro\nmore"
        // Caret at end of body: query would include a newline → nil.
        XCTAssertNil(SnippetInsertion.slashToken(in: text, atCaret: text.endIndex))
        // Caret still on the query: active.
        let afterIntro = text.range(of: "/intro")!.upperBound
        XCTAssertEqual(SnippetInsertion.slashToken(in: text, atCaret: afterIntro)?.query, "intro")
    }

    func testCaretUTF16MatchesStringIndex() {
        let text = "Hi\n/cal"
        let utf16 = (text as NSString).length
        let t = SnippetInsertion.slashToken(in: text, caretUTF16: utf16)
        XCTAssertEqual(t?.query, "cal")
    }

    func testEmptyQueryAtCaretShowsBrowseMode() {
        let text = "Hello\n/"
        let t = SnippetInsertion.slashToken(in: text, atCaret: text.endIndex)
        XCTAssertEqual(t?.query, "")
    }
}
