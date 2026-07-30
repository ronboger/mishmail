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

    /// Undo toast must reuse the shared formatter (no DateFormatter alloc on
    /// the triage hot path) and stay readable for tomorrow vs later dates.
    func testUndoLabelUsesSharedFormat() {
        // `format` uses Calendar.isDateInTomorrow relative to wall-clock now,
        // not the fixture `now` used by the parser suggestion tests.
        let wall = Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: wall)!
        let at9 = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
        let label = SnoozeDateParser.undoLabel(until: at9)
        XCTAssertEqual(label, "Snoozed until \(SnoozeDateParser.format(at9))")
        XCTAssertTrue(label.hasPrefix("Snoozed until "))
        XCTAssertTrue(label.contains("tomorrow"), label)
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

    func testBareHourIsMilitaryTime() {
        let c = comps(first("tm 20"))
        XCTAssertEqual([c.month, c.day, c.hour], [7, 8, 20])
    }

    func testBareHourMorning() {
        let c = comps(first("tm 10"))
        XCTAssertEqual([c.month, c.day, c.hour], [7, 8, 10])
    }

    func testBareHourAfterWeekday() {
        let c = comps(first("fri 15"))
        XCTAssertEqual([c.month, c.day, c.hour], [7, 10, 15])
    }

    func testMonthDayNotTreatedAsBareHour() {
        // "aug 12" must stay Aug 12, not August at hour 12.
        let c = comps(first("aug 12"))
        XCTAssertEqual([c.month, c.day], [8, 12])
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

    /// Typing `s` after `b` should surface weekend days + September — not
    /// leave the user with an empty suggestion list (or fall through to
    /// type-select, which is covered by DatePickQueryInputTests).
    func testSingleLetterSSuggestsSatSunSeptember() {
        let labels = SnoozeDateParser.suggestions(for: "s", now: now).map { $0.label.lowercased() }
        XCTAssertTrue(labels.contains(where: { $0.hasPrefix("saturday") }), labels.joined(separator: ", "))
        XCTAssertTrue(labels.contains(where: { $0.hasPrefix("sunday") }), labels.joined(separator: ", "))
        XCTAssertTrue(labels.contains(where: { $0.hasPrefix("september") }), labels.joined(separator: ", "))
    }

    func testSatAndSunWeekdayPrefixes() {
        let sat = comps(first("sat"))
        // Fixture now is Tuesday July 7 2026 → next Saturday is July 11.
        XCTAssertEqual([sat.month, sat.day], [7, 11])
        let sun = comps(first("sun"))
        // Next Sunday is July 12.
        XCTAssertEqual([sun.month, sun.day], [7, 12])
    }

    func testBareMonthSeptember() {
        for q in ["sep", "sept", "september"] {
            let c = comps(first(q))
            // July fixture → Sept 1 2026 still ahead.
            XCTAssertEqual([c.year, c.month, c.day, c.hour], [2026, 9, 1, 8], "\(q)")
        }
    }

    func testBareMonthPastRollsToNextYear() {
        // January is before July in the fixture year.
        let c = comps(first("january"))
        XCTAssertEqual([c.year, c.month, c.day], [2027, 1, 1])
    }

    func testSingleLetterWeekdayWithBareHour() {
        // "s 10" → first matching weekday (Sunday in en_US calendar symbols)
        // at 10:00, not an empty suggestion list.
        let c = comps(first("s 10"))
        XCTAssertEqual(c.hour, 10)
        XCTAssertNotNil(c.day)
    }

    // MARK: - Broader suggestion coverage

    func testLaterTodayAliasAndPrefix() {
        // Fixture is 10:00 → later today lands on afternoon (13:00).
        for q in ["l", "later", "later today", "lt"] {
            let c = comps(first(q))
            XCTAssertEqual([c.day, c.hour], [7, 13], "\(q)")
        }
    }

    func testEndOfDayAliases() {
        for q in ["eod", "end of day", "end"] {
            let labels = SnoozeDateParser.suggestions(for: q, now: now).map { $0.label.lowercased() }
            XCTAssertTrue(labels.contains(where: { $0.contains("end of day") }),
                          "\(q) → \(labels.joined(separator: ", "))")
        }
        let c = comps(first("eod"))
        // Evening = 18:00 today (still ahead of 10:00).
        XCTAssertEqual([c.day, c.hour], [7, 18])
    }

    func testEndOfWeekAndMonthAliases() {
        let eow = comps(first("eow"))
        // Next Friday after Tue Jul 7 2026 is Jul 10 at evening.
        XCTAssertEqual([eow.month, eow.day, eow.hour], [7, 10, 18])
        let eom = comps(first("eom"))
        // Last day of July 2026.
        XCTAssertEqual([eom.month, eom.day], [7, 31])
    }

    func testInPrefixLadder() {
        let labels = SnoozeDateParser.suggestions(for: "in", now: now).map { $0.label.lowercased() }
        XCTAssertTrue(labels.contains(where: { $0.hasPrefix("in 1 hour") }), labels.joined(separator: ", "))
        XCTAssertTrue(labels.contains(where: { $0.hasPrefix("in 1 day") }), labels.joined(separator: ", "))
        XCTAssertTrue(labels.contains(where: { $0.hasPrefix("in 1 week") }), labels.joined(separator: ", "))
    }

    func testSingleLetterISuggestsRelative() {
        let labels = SnoozeDateParser.suggestions(for: "i", now: now).map { $0.label.lowercased() }
        XCTAssertFalse(labels.isEmpty, "i should offer the in-… ladder")
        XCTAssertTrue(labels.contains(where: { $0.contains("hour") || $0.contains("day") }),
                      labels.joined(separator: ", "))
    }

    func testCompactRelativeDurations() {
        let h = comps(first("2h"))
        XCTAssertEqual(h.hour, 12)  // 10:00 + 2h
        let d = comps(first("3d"))
        XCTAssertEqual([d.month, d.day, d.hour], [7, 10, 8])
        let w = comps(first("1w"))
        XCTAssertEqual([w.month, w.day], [7, 14])
    }

    func testBareUnitWords() {
        let hour = comps(first("hour"))
        XCTAssertEqual(hour.hour, 11)  // +1h from 10:00
        let day = comps(first("day"))
        XCTAssertEqual([day.month, day.day], [7, 8])
        // "h" alone → in 1 hour
        let h = comps(first("h"))
        XCTAssertEqual(h.hour, 11)
    }

    func testInNWithPartialUnit() {
        let c = comps(first("in 2 da"))
        XCTAssertEqual([c.month, c.day, c.hour], [7, 9, 8])
    }

    func testBareTwoDaysWithoutIn() {
        let c = comps(first("2 days"))
        XCTAssertEqual([c.month, c.day, c.hour], [7, 9, 8])
    }

    func testWeekendAlias() {
        let c = comps(first("wknd"))
        // Next Saturday after Tue Jul 7 → Jul 11.
        XCTAssertEqual([c.month, c.day], [7, 11])
    }

    func testSingleLetterESuggestsEndOf() {
        let labels = SnoozeDateParser.suggestions(for: "e", now: now).map { $0.label.lowercased() }
        XCTAssertTrue(labels.contains(where: { $0.contains("end of day") }), labels.joined(separator: ", "))
        XCTAssertTrue(labels.contains(where: { $0.contains("end of week") }), labels.joined(separator: ", "))
    }

    func testSingleLetterFStillFridayAndFebruary() {
        let labels = SnoozeDateParser.suggestions(for: "f", now: now).map { $0.label.lowercased() }
        XCTAssertTrue(labels.contains(where: { $0.hasPrefix("friday") }), labels.joined(separator: ", "))
        XCTAssertTrue(labels.contains(where: { $0.hasPrefix("february") }), labels.joined(separator: ", "))
    }
}
