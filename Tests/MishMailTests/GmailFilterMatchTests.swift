import XCTest

/// Hostless tests for best-effort Gmail filter matching against message fields.
final class GmailFilterMatchTests: XCTestCase {

    private func fields(
        from: String = "Ada Lovelace <ada@analytical.engine>",
        to: String = "Charles Babbage <charles@diff.engine>",
        cc: String = "",
        subject: String = "Difference engine notes",
        snippet: String = "About the notes",
        bodyText: String = "Please review the plans for the mill.",
        hasAttachment: Bool = false,
        sizeBytes: Int? = nil
    ) -> GmailFilterMatch.MessageFields {
        .init(from: from, to: to, cc: cc, subject: subject,
              snippet: snippet, bodyText: bodyText,
              hasAttachment: hasAttachment, sizeBytes: sizeBytes)
    }

    private func filter(
        from: String? = nil, to: String? = nil, subject: String? = nil,
        query: String? = nil, negatedQuery: String? = nil,
        hasAttachment: Bool? = nil, size: Int? = nil,
        sizeComparison: String? = nil
    ) -> GFilter {
        GFilter(
            id: UUID().uuidString,
            criteria: .init(
                from: from, to: to, subject: subject, query: query,
                negatedQuery: negatedQuery, hasAttachment: hasAttachment,
                size: size, sizeComparison: sizeComparison),
            action: .init(addLabelIds: ["Label_1"], removeLabelIds: nil, forward: nil))
    }

    func testEmptyCriteriaMatchesEverything() {
        let f = GFilter(id: "1", criteria: nil, action: nil)
        XCTAssertTrue(GmailFilterMatch.matches(f, message: fields()))
    }

    func testFromMatchesEmailAndDisplayName() {
        XCTAssertTrue(GmailFilterMatch.matches(
            filter(from: "ada@analytical.engine"), message: fields()))
        XCTAssertTrue(GmailFilterMatch.matches(
            filter(from: "Lovelace"), message: fields()))
        XCTAssertFalse(GmailFilterMatch.matches(
            filter(from: "nobody@example.com"), message: fields()))
    }

    func testToMatchesCcAsWell() {
        let msg = fields(cc: "cc@example.com")
        XCTAssertTrue(GmailFilterMatch.matches(filter(to: "cc@example.com"), message: msg))
        XCTAssertTrue(GmailFilterMatch.matches(filter(to: "charles@diff.engine"), message: msg))
        XCTAssertFalse(GmailFilterMatch.matches(filter(to: "other@x.com"), message: msg))
    }

    func testSubjectSubstring() {
        XCTAssertTrue(GmailFilterMatch.matches(
            filter(subject: "engine"), message: fields()))
        XCTAssertFalse(GmailFilterMatch.matches(
            filter(subject: "unrelated"), message: fields()))
    }

    func testHasAttachment() {
        XCTAssertFalse(GmailFilterMatch.matches(
            filter(hasAttachment: true), message: fields(hasAttachment: false)))
        XCTAssertTrue(GmailFilterMatch.matches(
            filter(hasAttachment: true), message: fields(hasAttachment: true)))
    }

    func testSizeRequiresKnownBytes() {
        // Unknown size → conservative no-match when criterion present.
        XCTAssertFalse(GmailFilterMatch.matches(
            filter(size: 1000, sizeComparison: "larger"),
            message: fields(sizeBytes: nil)))
        XCTAssertTrue(GmailFilterMatch.matches(
            filter(size: 1000, sizeComparison: "larger"),
            message: fields(sizeBytes: 2000)))
        XCTAssertTrue(GmailFilterMatch.matches(
            filter(size: 1000, sizeComparison: "smaller"),
            message: fields(sizeBytes: 500)))
        XCTAssertFalse(GmailFilterMatch.matches(
            filter(size: 1000, sizeComparison: "smaller"),
            message: fields(sizeBytes: 1500)))
    }

    func testQueryOperatorsAndFreeText() {
        let msg = fields()
        XCTAssertTrue(GmailFilterMatch.matches(
            filter(query: "from:ada@analytical.engine"), message: msg))
        XCTAssertTrue(GmailFilterMatch.matches(
            filter(query: "subject:Difference"), message: msg))
        XCTAssertTrue(GmailFilterMatch.matches(
            filter(query: "plans"), message: msg))  // in body
        XCTAssertFalse(GmailFilterMatch.matches(
            filter(query: "from:ada plans XYZNOPE"), message: msg))
        XCTAssertTrue(GmailFilterMatch.matches(
            filter(query: "has:attachment"), message: fields(hasAttachment: true)))
    }

    func testQueryORMatchesEitherSide() {
        let msg = fields()  // from ada@analytical.engine
        XCTAssertTrue(GmailFilterMatch.matches(
            filter(query: "from:ada@analytical.engine OR from:nobody@example.com"),
            message: msg))
        XCTAssertTrue(GmailFilterMatch.matches(
            filter(query: "from:nobody@example.com OR from:ada"),
            message: msg))
        XCTAssertFalse(GmailFilterMatch.matches(
            filter(query: "from:nobody@example.com OR from:other@x.com"),
            message: msg))
        // OR must not require the literal substring "or" in the body.
        let noOrBody = fields(bodyText: "Please review the plans for the mill.")
        XCTAssertTrue(GmailFilterMatch.matches(
            filter(query: "from:ada OR from:ghost@x.com"),
            message: noOrBody))
    }

    func testQueryORCaseInsensitiveAndQuoted() {
        let msg = fields()
        XCTAssertTrue(GmailFilterMatch.matches(
            filter(query: "from:ghost or from:ada"), message: msg))
        // OR inside quotes is free text, not an operator.
        XCTAssertFalse(GmailFilterMatch.matches(
            filter(query: #""from:ada OR from:ghost""#), message: msg))
    }

    func testQueryUnaryNegation() {
        let msg = fields()
        XCTAssertFalse(GmailFilterMatch.matches(
            filter(query: "from:ada -plans"), message: msg))  // body has plans
        XCTAssertTrue(GmailFilterMatch.matches(
            filter(query: "from:ada -xyzzy"), message: msg))
        XCTAssertTrue(GmailFilterMatch.matches(
            filter(query: "-from:nobody@example.com"), message: msg))
    }

    func testNegatedQuery() {
        XCTAssertFalse(GmailFilterMatch.matches(
            filter(negatedQuery: "plans"), message: fields()))
        XCTAssertTrue(GmailFilterMatch.matches(
            filter(negatedQuery: "xyzzy"), message: fields()))
    }

    func testQuotedPhraseToken() {
        let tokens = GmailFilterMatch.tokenize(#"from:ada "Difference engine" notes"#)
        XCTAssertEqual(tokens, ["from:ada", "Difference engine", "notes"])
    }

    func testSplitTopLevelOR() {
        XCTAssertEqual(
            GmailFilterMatch.splitTopLevelOR("from:a OR from:b"),
            ["from:a", "from:b"])
        XCTAssertEqual(
            GmailFilterMatch.splitTopLevelOR(#"subject:"x OR y" from:z"#),
            [#"subject:"x OR y" from:z"#])
    }

    func testMatchingPreservesOrder() {
        let a = filter(from: "ada@analytical.engine")
        let b = filter(from: "nobody@x.com")
        let c = filter(subject: "Difference")
        let hits = GmailFilterMatch.matching([a, b, c], message: fields())
        XCTAssertEqual(hits.map(\.id), [a.id, c.id])
    }

    func testAllCriteriaMustMatch() {
        // from hits, subject misses → overall false
        XCTAssertFalse(GmailFilterMatch.matches(
            filter(from: "ada", subject: "nope"), message: fields()))
    }
}
