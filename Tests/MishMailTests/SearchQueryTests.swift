import XCTest

final class SearchQueryTests: XCTestCase {

    func testPlainTextIsFullText() {
        let q = SearchQuery.parse("quarterly report")
        XCTAssertEqual(q.text, "quarterly report")
        XCTAssertNil(q.from)
        XCTAssertTrue(q.labels.isEmpty)
        XCTAssertFalse(q.hasAttachment)
    }

    func testFromOperator() {
        let q = SearchQuery.parse("from:alice@example.com")
        XCTAssertEqual(q.from, "alice@example.com")
        XCTAssertEqual(q.text, "")
        XCTAssertTrue(q.isFilterOnly)
    }

    func testQuotedFromKeepsSpaces() {
        let q = SearchQuery.parse("from:\"Alice Smith\" invoice")
        XCTAssertEqual(q.from, "Alice Smith")
        XCTAssertEqual(q.text, "invoice")
    }

    func testLabelOperatorMultiple() {
        let q = SearchQuery.parse("label:work label:\"Deal Flow\"")
        XCTAssertEqual(q.labels, ["work", "Deal Flow"])
        XCTAssertTrue(q.isFilterOnly)
    }

    func testHasAttachment() {
        let q = SearchQuery.parse("has:attachment tax")
        XCTAssertTrue(q.hasAttachment)
        XCTAssertEqual(q.text, "tax")
    }

    func testOperatorsAreCaseInsensitive() {
        let q = SearchQuery.parse("FROM:bob HAS:ATTACHMENT Label:Work")
        XCTAssertEqual(q.from, "bob")
        XCTAssertTrue(q.hasAttachment)
        XCTAssertEqual(q.labels, ["Work"])
    }

    func testCombinedOperatorsAndText() {
        let q = SearchQuery.parse("from:carol label:receipts has:attachment flight to SFO")
        XCTAssertEqual(q.from, "carol")
        XCTAssertEqual(q.labels, ["receipts"])
        XCTAssertTrue(q.hasAttachment)
        XCTAssertEqual(q.text, "flight to SFO")
        XCTAssertFalse(q.isFilterOnly)
    }

    func testEmptyOperatorValueIgnored() {
        let q = SearchQuery.parse("from: hello")
        XCTAssertNil(q.from)
        XCTAssertEqual(q.text, "hello")
    }

    func testHasSomethingElseIsText() {
        // Only has:attachment is an operator; other has: tokens stay text.
        let q = SearchQuery.parse("has:coffee")
        XCTAssertFalse(q.hasAttachment)
        XCTAssertEqual(q.text, "has:coffee")
    }

    func testColonInsideWordIsNotOperator() {
        let q = SearchQuery.parse("re: meeting 10:30")
        XCTAssertEqual(q.text, "re: meeting 10:30")
    }

    func testToAndSubjectOperators() {
        let q = SearchQuery.parse("to:bob@x.com subject:\"Q3 numbers\" draft")
        XCTAssertEqual(q.to, "bob@x.com")
        XCTAssertEqual(q.subject, "Q3 numbers")
        XCTAssertEqual(q.text, "draft")
    }

    func testIsUnreadReadStarred() {
        XCTAssertEqual(SearchQuery.parse("is:unread").unread, true)
        XCTAssertEqual(SearchQuery.parse("is:read").unread, false)
        XCTAssertNil(SearchQuery.parse("hello").unread)
        XCTAssertTrue(SearchQuery.parse("is:starred").starred)
        XCTAssertTrue(SearchQuery.parse("is:unread is:starred").isFilterOnly)
    }

    func testUnknownIsValueStaysText() {
        let q = SearchQuery.parse("is:coffee")
        XCTAssertNil(q.unread)
        XCTAssertFalse(q.starred)
        XCTAssertEqual(q.text, "is:coffee")
    }

    func testDateOperatorsParse() {
        let q = SearchQuery.parse("after:2026/07/01 before:2026-07-31 report")
        XCTAssertEqual(q.text, "report")
        let cal = Calendar.current
        let a = try? XCTUnwrap(q.after)
        let b = try? XCTUnwrap(q.before)
        XCTAssertEqual(cal.dateComponents([.year, .month, .day], from: a!),
                       DateComponents(year: 2026, month: 7, day: 1))
        XCTAssertEqual(cal.dateComponents([.year, .month, .day], from: b!),
                       DateComponents(year: 2026, month: 7, day: 31))
        // Start-of-day normalization.
        XCTAssertEqual(cal.component(.hour, from: a!), 0)
    }

    func testInvalidDateStaysText() {
        let q = SearchQuery.parse("after:notadate before:2026/13/40")
        XCTAssertNil(q.after)
        XCTAssertNil(q.before)
        XCTAssertEqual(q.text, "after:notadate before:2026/13/40")
    }

    func testImpossibleDaysAreRejectedNotRolledOver() {
        // Calendar.date(from:) silently rolls Feb 30 → Mar 2; parseDate must
        // reject these so a typo becomes free text instead of a wrong bound.
        for bad in ["after:2026/02/30", "after:2026/04/31", "after:2026/06/31",
                    "after:2026/02/29", "after:2026/00/10", "after:2026/07/00"] {
            let q = SearchQuery.parse(bad)
            XCTAssertNil(q.after, "\(bad) should not parse to a date")
            XCTAssertEqual(q.text, bad, "\(bad) should remain free text")
        }
        // A real leap day still parses.
        XCTAssertNotNil(SearchQuery.parse("after:2028/02/29").after)
    }

    func testDefaultLocationExcludesTrashAndSpam() {
        let q = SearchQuery.parse("invoice")
        XCTAssertEqual(q.location, .standard)
        XCTAssertTrue(q.includesLocation(inTrash: false, inSpam: false))
        XCTAssertFalse(q.includesLocation(inTrash: true, inSpam: false),
                       "trashed threads must leave default search results")
        XCTAssertFalse(q.includesLocation(inTrash: false, inSpam: true),
                       "spam threads must leave default search results")
    }

    func testInTrashOperator() {
        let q = SearchQuery.parse("in:trash quarterly")
        XCTAssertEqual(q.location, .trash)
        XCTAssertEqual(q.text, "quarterly")
        XCTAssertTrue(q.includesLocation(inTrash: true, inSpam: false))
        XCTAssertFalse(q.includesLocation(inTrash: false, inSpam: false))
        XCTAssertFalse(q.includesLocation(inTrash: false, inSpam: true))
        XCTAssertTrue(q.isFilterOnly == false)
        XCTAssertTrue(SearchQuery.parse("in:trash").isFilterOnly)
    }

    func testInSpamAndInAnywhereOperators() {
        let spam = SearchQuery.parse("IN:SPAM")
        XCTAssertEqual(spam.location, .spam)
        XCTAssertTrue(spam.includesLocation(inTrash: false, inSpam: true))
        XCTAssertFalse(spam.includesLocation(inTrash: true, inSpam: false))

        let anywhere = SearchQuery.parse("in:anywhere report")
        XCTAssertEqual(anywhere.location, .anywhere)
        XCTAssertEqual(anywhere.text, "report")
        XCTAssertTrue(anywhere.includesLocation(inTrash: true, inSpam: false))
        XCTAssertTrue(anywhere.includesLocation(inTrash: false, inSpam: true))
        XCTAssertTrue(anywhere.includesLocation(inTrash: false, inSpam: false))
    }

    func testUnknownInValueStaysText() {
        let q = SearchQuery.parse("in:inbox hello")
        XCTAssertEqual(q.location, .standard)
        XCTAssertEqual(q.text, "in:inbox hello")
    }
}
