import XCTest

final class SnoozeDateParserTests: XCTestCase {
    // Tuesday July 7 2026, 10:00 local time.
    private let now = Calendar.current.date(from: DateComponents(
        year: 2026, month: 7, day: 7, hour: 10))!

    private func first(_ query: String) -> Date? {
        SnoozeDateParser.suggestions(for: query, now: now).first?.date
    }
    private func comps(_ date: Date?) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date!)
    }

    func testTomorrowDefaultsToMorning() {
        let c = comps(first("tom"))
        XCTAssertEqual([c.month, c.day, c.hour], [7, 8, 8])
    }

    func testWeekdayPrefixWithTime() {
        let c = comps(first("fri 3pm"))
        XCTAssertEqual([c.month, c.day, c.hour], [7, 10, 15])
    }

    func testInNDays() {
        let c = comps(first("in 2 weeks"))
        XCTAssertEqual([c.month, c.day, c.hour], [7, 21, 8])
    }

    func testMonthDayRollsToNextYearWhenPast() {
        let c = comps(first("jan 5"))
        XCTAssertEqual([c.year, c.month, c.day], [2027, 1, 5])
    }

    func testMonthDayThisYear() {
        let c = comps(first("aug 12 at 17:30"))
        XCTAssertEqual([c.month, c.day, c.hour, c.minute], [8, 12, 17, 30])
    }

    func testSlashDate() {
        let c = comps(first("8/12"))
        XCTAssertEqual([c.month, c.day], [8, 12])
    }

    func testBareTimeTodayIfFuture() {
        let c = comps(first("3pm"))
        XCTAssertEqual([c.day, c.hour], [7, 15])
    }

    func testBareTimePastRollsToTomorrow() {
        let s = SnoozeDateParser.suggestions(for: "9am", now: now)
        // 9am already passed at 10:00 — only tomorrow qualifies.
        let c = comps(s.first?.date)
        XCTAssertEqual([c.day, c.hour], [8, 9])
    }

    func testEveningKeyword() {
        let c = comps(first("today evening"))
        XCTAssertEqual([c.day, c.hour], [7, 18])
    }

    func testNextWeekIsMonday() {
        let c = comps(first("next week"))
        XCTAssertEqual([c.month, c.day], [7, 13])
    }

    func testTomorrowAbbreviationWithTime() {
        let c = comps(first("tm 10am"))
        XCTAssertEqual([c.month, c.day, c.hour], [7, 8, 10])
    }

    func testTomorrowAbbreviationVariants() {
        for q in ["tmrw", "tmr", "tmw"] {
            let c = comps(first(q))
            XCTAssertEqual([c.month, c.day], [7, 8], "\(q) should be tomorrow")
        }
    }

    func testMonthDayWithFourDigitYear() {
        let c = comps(first("aug 17 2027"))
        XCTAssertEqual([c.year, c.month, c.day], [2027, 8, 17])
    }

    func testMonthDayWithYearAndTime() {
        let c = comps(first("aug 17 2027 3pm"))
        XCTAssertEqual([c.year, c.month, c.day, c.hour], [2027, 8, 17, 15])
    }

    func testSlashDateWithTwoDigitYear() {
        let c = comps(first("8/12/27"))
        XCTAssertEqual([c.year, c.month, c.day], [2027, 8, 12])
    }

    func testDayMonthYear() {
        let c = comps(first("17 aug 2027"))
        XCTAssertEqual([c.year, c.month, c.day], [2027, 8, 17])
    }

    func testEmptyAndGarbage() {
        XCTAssertTrue(SnoozeDateParser.suggestions(for: "", now: now).isEmpty)
        XCTAssertTrue(SnoozeDateParser.suggestions(for: "zzzz", now: now).isEmpty)
    }

    func testOnlyFutureDates() {
        for s in SnoozeDateParser.suggestions(for: "today", now: now) {
            XCTAssertGreaterThan(s.date, now)
        }
    }
}
