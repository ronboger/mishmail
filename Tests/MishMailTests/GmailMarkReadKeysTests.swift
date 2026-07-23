import XCTest

final class GmailMarkReadKeysTests: XCTestCase {
    func testShiftIMarksRead() {
        XCTAssertEqual(GmailMarkReadKeys.markAsRead(key: "I", shiftOnly: true), true)
        XCTAssertEqual(GmailMarkReadKeys.markAsRead(key: "i", shiftOnly: true), true)
    }

    func testShiftUMarksUnread() {
        XCTAssertEqual(GmailMarkReadKeys.markAsRead(key: "U", shiftOnly: true), false)
        XCTAssertEqual(GmailMarkReadKeys.markAsRead(key: "u", shiftOnly: true), false)
    }

    func testPlainOrModifiedKeysIgnored() {
        XCTAssertNil(GmailMarkReadKeys.markAsRead(key: "i", shiftOnly: false))
        XCTAssertNil(GmailMarkReadKeys.markAsRead(key: "u", shiftOnly: false))
        XCTAssertNil(GmailMarkReadKeys.markAsRead(key: "I", shiftOnly: false))
        XCTAssertNil(GmailMarkReadKeys.markAsRead(key: "e", shiftOnly: true))
        XCTAssertNil(GmailMarkReadKeys.markAsRead(key: "!", shiftOnly: true))
        XCTAssertNil(GmailMarkReadKeys.markAsRead(key: "", shiftOnly: true))
        XCTAssertNil(GmailMarkReadKeys.markAsRead(key: "ii", shiftOnly: true))
    }
}
