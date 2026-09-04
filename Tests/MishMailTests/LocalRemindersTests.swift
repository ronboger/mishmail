import XCTest

final class LocalRemindersTests: XCTestCase {

    func testInboundReplyAfterSetCancels() {
        let setAt = Date(timeIntervalSince1970: 100)
        let inbound = Date(timeIntervalSince1970: 200)
        XCTAssertTrue(LocalReminders.inboundReplyCancels(
            reminderSetAt: setAt, lastInboundDate: inbound))
    }

    func testOwnFollowUpDoesNotCancel() {
        let setAt = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(LocalReminders.inboundReplyCancels(
            reminderSetAt: setAt, lastInboundDate: nil),
                       "pure-outbound threads have no inbound date")
        XCTAssertFalse(LocalReminders.inboundReplyCancels(
            reminderSetAt: setAt,
            lastInboundDate: Date(timeIntervalSince1970: 50)),
                       "older inbound mail is not a reply")
    }

    func testClearWithoutSetDoesNotCancel() {
        XCTAssertFalse(LocalReminders.inboundReplyCancels(
            reminderSetAt: nil, lastInboundDate: Date()))
    }

    func testFireAtAddsDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let fire = LocalReminders.fireAt(after: 2, now: now, calendar: cal)
        XCTAssertEqual(fire, cal.date(byAdding: .day, value: 2, to: now))
        XCTAssertNil(LocalReminders.fireAt(after: nil, now: now, calendar: cal))
    }

    func testClearSQLMatchesCompareAndClearPredicate() {
        XCTAssertTrue(LocalReminders.clearSQL.contains("AND reminderAt = ?"))
        XCTAssertTrue(LocalReminders.clearSQL.contains("reminderSetAt = NULL"))
    }
}
