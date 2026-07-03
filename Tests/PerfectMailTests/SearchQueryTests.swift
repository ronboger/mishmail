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
}
