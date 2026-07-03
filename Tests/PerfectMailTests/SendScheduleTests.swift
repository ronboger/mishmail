import XCTest

final class SendScheduleTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // Friday 2026-07-03, 10:15.
    private var friday: Date { date(2026, 7, 3, 10, 15) }

    func testTomorrowMorningIs8AMNextDay() {
        XCTAssertEqual(SendSchedule.tomorrowMorning.date(after: friday, calendar: cal),
                       date(2026, 7, 4, 8, 0))
    }

    func testTomorrowAfternoonIs1PMNextDay() {
        XCTAssertEqual(SendSchedule.tomorrowAfternoon.date(after: friday, calendar: cal),
                       date(2026, 7, 4, 13, 0))
    }

    func testMondayMorningFromFriday() {
        XCTAssertEqual(SendSchedule.mondayMorning.date(after: friday, calendar: cal),
                       date(2026, 7, 6, 8, 0))
    }

    /// From a Monday, "Monday morning" means NEXT Monday, never today.
    func testMondayMorningFromMondayIsAWeekOut() {
        let monday = date(2026, 7, 6, 9, 0)
        XCTAssertEqual(SendSchedule.mondayMorning.date(after: monday, calendar: cal),
                       date(2026, 7, 13, 8, 0))
    }

    /// Late-night scheduling still lands on the calendar next day.
    func testTomorrowMorningAcrossMonthBoundary() {
        let endOfMonth = date(2026, 7, 31, 23, 30)
        XCTAssertEqual(SendSchedule.tomorrowMorning.date(after: endOfMonth, calendar: cal),
                       date(2026, 8, 1, 8, 0))
    }

    func testDescribeTodayAndTomorrow() {
        let now = friday
        XCTAssertTrue(SendSchedule.describe(date(2026, 7, 3, 17, 0), relativeTo: now, calendar: cal)
            .hasPrefix("today at "))
        XCTAssertTrue(SendSchedule.describe(date(2026, 7, 4, 8, 0), relativeTo: now, calendar: cal)
            .hasPrefix("tomorrow at "))
        // Further out: named day, no "today"/"tomorrow".
        let monday = SendSchedule.describe(date(2026, 7, 6, 8, 0), relativeTo: now, calendar: cal)
        XCTAssertTrue(monday.contains("at "))
        XCTAssertFalse(monday.hasPrefix("today"))
        XCTAssertFalse(monday.hasPrefix("tomorrow"))
    }
}
