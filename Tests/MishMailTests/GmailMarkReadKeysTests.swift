import XCTest

final class GmailMarkReadKeysTests: XCTestCase {
    func testShiftIChord() {
        XCTAssertEqual(GmailMarkReadKeys.chord(key: "I", shiftOnly: true), .shiftI)
        XCTAssertEqual(GmailMarkReadKeys.chord(key: "i", shiftOnly: true), .shiftI)
        XCTAssertEqual(GmailMarkReadKeys.markAsRead(key: "I", shiftOnly: true), true)
        XCTAssertEqual(GmailMarkReadKeys.markAsRead(key: "i", shiftOnly: true), true)
    }

    func testShiftUChord() {
        XCTAssertEqual(GmailMarkReadKeys.chord(key: "U", shiftOnly: true), .shiftU)
        XCTAssertEqual(GmailMarkReadKeys.chord(key: "u", shiftOnly: true), .shiftU)
        XCTAssertEqual(GmailMarkReadKeys.markAsRead(key: "U", shiftOnly: true), false)
        XCTAssertEqual(GmailMarkReadKeys.markAsRead(key: "u", shiftOnly: true), false)
    }

    func testPlainOrModifiedKeysIgnored() {
        XCTAssertNil(GmailMarkReadKeys.chord(key: "i", shiftOnly: false))
        XCTAssertNil(GmailMarkReadKeys.chord(key: "u", shiftOnly: false))
        XCTAssertNil(GmailMarkReadKeys.chord(key: "I", shiftOnly: false))
        XCTAssertNil(GmailMarkReadKeys.chord(key: "e", shiftOnly: true))
        XCTAssertNil(GmailMarkReadKeys.chord(key: "!", shiftOnly: true))
        XCTAssertNil(GmailMarkReadKeys.chord(key: "", shiftOnly: true))
        XCTAssertNil(GmailMarkReadKeys.chord(key: "ii", shiftOnly: true))
        XCTAssertNil(GmailMarkReadKeys.markAsRead(key: "i", shiftOnly: false))
        XCTAssertNil(GmailMarkReadKeys.markAsRead(key: "u", shiftOnly: false))
        XCTAssertNil(GmailMarkReadKeys.markAsRead(key: "I", shiftOnly: false))
        XCTAssertNil(GmailMarkReadKeys.markAsRead(key: "e", shiftOnly: true))
        XCTAssertNil(GmailMarkReadKeys.markAsRead(key: "!", shiftOnly: true))
        XCTAssertNil(GmailMarkReadKeys.markAsRead(key: "", shiftOnly: true))
        XCTAssertNil(GmailMarkReadKeys.markAsRead(key: "ii", shiftOnly: true))
    }

    func testShiftIMarksReadWhenAnyUnread() {
        XCTAssertEqual(
            GmailMarkReadKeys.desiredRead(chord: .shiftI, anyUnread: true), true)
    }

    func testShiftIMarksUnreadWhenAllAlreadyRead() {
        // Fully-read selection: Shift+I flips to unread instead of no-op.
        XCTAssertEqual(
            GmailMarkReadKeys.desiredRead(chord: .shiftI, anyUnread: false), false)
    }

    func testShiftUAlwaysMarksUnread() {
        XCTAssertEqual(
            GmailMarkReadKeys.desiredRead(chord: .shiftU, anyUnread: true), false)
        XCTAssertEqual(
            GmailMarkReadKeys.desiredRead(chord: .shiftU, anyUnread: false), false)
    }
}
