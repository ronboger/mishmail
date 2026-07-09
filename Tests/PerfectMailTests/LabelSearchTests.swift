import XCTest
/// The shared label-search predicate used by the "l" picker and the Labels
/// filter chip. Regression: "inv" must match every label containing it,
/// regardless of case ("Investment Updates" AND "investor updates").
final class LabelSearchTests: XCTestCase {

    func testPrefixMatchesRegardlessOfCase() {
        XCTAssertTrue(LabelSearch.matches("Investment Updates", query: "inv"))
        XCTAssertTrue(LabelSearch.matches("investor updates", query: "inv"))
        XCTAssertTrue(LabelSearch.matches("investor updates", query: "INV"))
        XCTAssertTrue(LabelSearch.matches("Investment Updates", query: "Inv"))
    }

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(LabelSearch.matches("Anything", query: ""))
        XCTAssertTrue(LabelSearch.matches("Anything", query: "   "))
    }

    func testEveryTokenMustMatch() {
        XCTAssertTrue(LabelSearch.matches("investor updates", query: "inv up"))
        XCTAssertTrue(LabelSearch.matches("investor updates", query: "up inv"))
        XCTAssertFalse(LabelSearch.matches("investor updates", query: "inv tax"))
    }

    func testMidWordAndDiacritics() {
        XCTAssertTrue(LabelSearch.matches("Investment", query: "vest"))
        XCTAssertTrue(LabelSearch.matches("Café receipts", query: "cafe"))
    }

    func testHighlightBoldsTheMatchedRange() {
        let attributed = LabelSearch.highlighted("Investment Updates", query: "inv")
        let run = attributed.runs.first { $0.inlinePresentationIntent == .stronglyEmphasized }
        XCTAssertEqual(run.map { String(attributed[$0.range].characters) }, "Inv")
    }

    func testHighlightIsCaseInsensitiveOfQuery() {
        let attributed = LabelSearch.highlighted("investor updates", query: "INV")
        let run = attributed.runs.first { $0.inlinePresentationIntent == .stronglyEmphasized }
        XCTAssertEqual(run.map { String(attributed[$0.range].characters) }, "inv")
    }

    func testHighlightWithEmptyQueryBoldsNothing() {
        let attributed = LabelSearch.highlighted("Investment Updates", query: "")
        XCTAssertNil(attributed.runs.first { $0.inlinePresentationIntent == .stronglyEmphasized })
    }
}
