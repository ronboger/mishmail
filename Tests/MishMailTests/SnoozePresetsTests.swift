import XCTest

final class SnoozePresetsTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func titles(at now: Date) -> [String] {
        SnoozePresets.presets(now: now, calendar: cal).map(\.title)
    }

    private func preset(_ title: String, at now: Date) -> Date? {
        SnoozePresets.presets(now: now, calendar: cal)
            .first(where: { $0.title == title })?.date
    }

    // MARK: - Late night (the screenshot bug: 12:55 AM)

    /// At 12:55 AM the first option must be *this* morning (today 8am), not
    /// "This evening / today 6pm" or "Tomorrow morning" (next calendar day).
    func testLateNightOffersThisMorningFirst() {
        // Thursday 2026-07-16 00:55 — matches the reported screenshot day.
        let now = date(2026, 7, 16, 0, 55)
        let list = SnoozePresets.presets(now: now, calendar: cal)

        XCTAssertEqual(list.first?.title, "This morning")
        XCTAssertEqual(list.first?.date, date(2026, 7, 16, 8, 0))

        XCTAssertEqual(preset("This afternoon", at: now), date(2026, 7, 16, 13, 0))
        XCTAssertEqual(preset("This evening", at: now), date(2026, 7, 16, 18, 0))
        XCTAssertEqual(preset("Tomorrow morning", at: now), date(2026, 7, 17, 8, 0))

        // Chronological: morning < afternoon < evening < tomorrow morning.
        let times = list.map(\.date)
        XCTAssertEqual(times, times.sorted())
    }

    func testLateNightTitlesIncludeDayparts() {
        let now = date(2026, 7, 16, 0, 55)
        let t = titles(at: now)
        XCTAssertTrue(t.contains("This morning"))
        XCTAssertTrue(t.contains("This afternoon"))
        XCTAssertTrue(t.contains("This evening"))
        XCTAssertTrue(t.contains("Tomorrow morning"))
        XCTAssertTrue(t.contains("This weekend"))
        XCTAssertTrue(t.contains("Next week"))
    }

    // MARK: - Mid-day / evening drop past anchors

    func testMidMorningDropsThisMorning() {
        let now = date(2026, 7, 16, 10, 0)
        let t = titles(at: now)
        XCTAssertFalse(t.contains("This morning"))
        XCTAssertEqual(t.first, "This afternoon")
        XCTAssertEqual(preset("This afternoon", at: now), date(2026, 7, 16, 13, 0))
        XCTAssertEqual(preset("This evening", at: now), date(2026, 7, 16, 18, 0))
        XCTAssertEqual(preset("Tomorrow morning", at: now), date(2026, 7, 17, 8, 0))
    }

    func testAfterEveningOnlyTomorrowAndBeyond() {
        let now = date(2026, 7, 16, 19, 30)
        let t = titles(at: now)
        XCTAssertFalse(t.contains("This morning"))
        XCTAssertFalse(t.contains("This afternoon"))
        XCTAssertFalse(t.contains("This evening"))
        XCTAssertEqual(t.first, "Tomorrow morning")
        XCTAssertEqual(preset("Tomorrow morning", at: now), date(2026, 7, 17, 8, 0))
    }

    func testExactlyAtMorningHourIsNotOffered() {
        // Anchor must be strictly in the future; at 8:00:00 "This morning"
        // has already arrived.
        let now = date(2026, 7, 16, 8, 0)
        XCTAssertNil(preset("This morning", at: now))
        XCTAssertEqual(titles(at: now).first, "This afternoon")
    }

    // MARK: - Weekend / next week

    func testWeekendIsNextSaturdayMorning() {
        // Thursday → Saturday Jul 18.
        let now = date(2026, 7, 16, 0, 55)
        XCTAssertEqual(preset("This weekend", at: now), date(2026, 7, 18, 8, 0))
    }

    func testNextWeekIsNextMondayMorning() {
        // Thursday → Monday Jul 20.
        let now = date(2026, 7, 16, 0, 55)
        XCTAssertEqual(preset("Next week", at: now), date(2026, 7, 20, 8, 0))
    }

    /// From a Monday, "Next week" is the *following* Monday, not today.
    func testNextWeekFromMondaySkipsToday() {
        let monday = date(2026, 7, 13, 9, 0)  // a Monday
        XCTAssertEqual(preset("Next week", at: monday), date(2026, 7, 20, 8, 0))
    }

    // MARK: - Month boundary

    func testTomorrowMorningAcrossMonthBoundary() {
        let now = date(2026, 7, 31, 23, 30)
        XCTAssertEqual(preset("Tomorrow morning", at: now), date(2026, 8, 1, 8, 0))
    }
}
