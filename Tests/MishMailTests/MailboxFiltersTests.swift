import XCTest

final class MailboxFiltersTests: XCTestCase {
    func testConflictingSavedFlagsNormalizeAndSurviveRoundTrip() throws {
        let legacy = Data(#"{"readOnly":true,"unreadOnly":true,"noAttachmentOnly":true,"hasAttachmentOnly":true,"senderContains":"Ada","hideCalendar":true}"#.utf8)
        let filters = try JSONDecoder().decode(FilterChips.self, from: legacy)
        XCTAssertEqual(filters.read, .unread)
        XCTAssertEqual(filters.attachments, .present)
        XCTAssertEqual(filters.calendar, .absent)
        XCTAssertEqual(filters.senderContains, "Ada")
        let data = try JSONEncoder().encode(filters)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(encoded["readOnly"] as? Bool, false)
        XCTAssertEqual(encoded["noAttachmentOnly"] as? Bool, false)
        XCTAssertEqual(try JSONDecoder().decode(FilterChips.self, from: data), filters)
    }
}
