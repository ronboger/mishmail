import XCTest

final class GmailMarkReadKeysTests: XCTestCase {
    func testShiftIChord() {
        XCTAssertEqual(GmailMarkReadKeys.chord(key: "I", shiftOnly: true), .shiftI)
        XCTAssertEqual(GmailMarkReadKeys.chord(key: "i", shiftOnly: true), .shiftI)
    }

    func testShiftUChord() {
        XCTAssertEqual(GmailMarkReadKeys.chord(key: "U", shiftOnly: true), .shiftU)
        XCTAssertEqual(GmailMarkReadKeys.chord(key: "u", shiftOnly: true), .shiftU)
    }

    func testPlainOrModifiedKeysIgnored() {
        XCTAssertNil(GmailMarkReadKeys.chord(key: "i", shiftOnly: false))
        XCTAssertNil(GmailMarkReadKeys.chord(key: "u", shiftOnly: false))
        XCTAssertNil(GmailMarkReadKeys.chord(key: "I", shiftOnly: false))
        XCTAssertNil(GmailMarkReadKeys.chord(key: "e", shiftOnly: true))
        XCTAssertNil(GmailMarkReadKeys.chord(key: "!", shiftOnly: true))
        XCTAssertNil(GmailMarkReadKeys.chord(key: "", shiftOnly: true))
        XCTAssertNil(GmailMarkReadKeys.chord(key: "ii", shiftOnly: true))
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
