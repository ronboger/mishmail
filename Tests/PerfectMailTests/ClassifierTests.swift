import XCTest

final class ClassifierTests: XCTestCase {

    func testExactCategoryNameWins() {
        XCTAssertEqual(Classifier.normalize("Reply needed"), "Reply needed")
        XCTAssertEqual(Classifier.normalize("This is FYI"), "FYI")
        XCTAssertEqual(Classifier.normalize("Category: Newsletter"), "Newsletter")
    }

    func testChattyResponseIsNormalized() {
        // Models often pad the answer; we still extract the category.
        XCTAssertEqual(Classifier.normalize("The best category here is Receipt."), "Receipt")
    }

    func testKeywordFallbacks() {
        XCTAssertEqual(Classifier.normalize("you should respond to this"), "Reply needed")
        XCTAssertEqual(Classifier.normalize("weekly digest of updates"), "Newsletter")
        XCTAssertEqual(Classifier.normalize("your invoice is attached"), "Receipt")
    }

    func testUnknownDefaultsToOther() {
        XCTAssertEqual(Classifier.normalize("banana"), "Other")
        XCTAssertEqual(Classifier.normalize(""), "Other")
    }

    func testRespectsCustomCategorySet() {
        let cats = ["Urgent", "Later"]
        // "reply" keyword maps to "Reply needed", which isn't enabled here, so
        // it falls through to the default (last) category.
        XCTAssertEqual(Classifier.normalize("please reply", categories: cats), "Later")
        XCTAssertEqual(Classifier.normalize("this is Urgent", categories: cats), "Urgent")
    }
}
