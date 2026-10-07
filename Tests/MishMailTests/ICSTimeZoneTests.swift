import XCTest

final class ICSTimeZoneTests: XCTestCase {

    private func zone(_ body: String, tzid: String = "Custom") -> ICSTimeZone? {
        let ics = "BEGIN:VTIMEZONE\nTZID:\(tzid)\n\(body)\nEND:VTIMEZONE"
        return ICSTimeZone.parseAll(CalendarInvite.unfold(ics))[tzid]
    }

    private func wall(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> TimeInterval {
        ICSTimeZone.wallTime(year: y, month: mo, day: d, hour: h, minute: mi, second: 0)!
    }

    /// Every local noon of 2025–2027 must agree with the tz database.
    private func assertMatches(_ zone: ICSTimeZone, iana: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: iana)!
        var day = wall(2025, 1, 1)
        let last = wall(2027, 12, 31)
        while day <= last {
            let c = ICSTimeZone.utcCalendar.dateComponents(
                [.year, .month, .day], from: Date(timeIntervalSince1970: day))
            let real = cal.date(from: DateComponents(
                year: c.year, month: c.month, day: c.day, hour: 12))!
            XCTAssertEqual(zone.offset(atLocal: day), cal.timeZone.secondsFromGMT(for: real),
                           "\(c.year!)-\(c.month!)-\(c.day!)", file: file, line: line)
            day += 86_400
        }
    }

    // Outlook writes DTSTART:1601… with a rule the start date does not match.
    private let outlookEastern = """
        BEGIN:STANDARD
        DTSTART:16010101T020000
        TZOFFSETFROM:-0400
        TZOFFSETTO:-0500
        RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=1SU;BYMONTH=11
        END:STANDARD
        BEGIN:DAYLIGHT
        DTSTART:16010101T020000
        TZOFFSETFROM:-0500
        TZOFFSETTO:-0400
        RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=2SU;BYMONTH=3
        END:DAYLIGHT
        """

    func testNorthernRulesMatchTZDatabase() throws {
        let tz = try XCTUnwrap(zone(outlookEastern))
        assertMatches(tz, iana: "America/New_York")
        // The hour before / after each 2026 change (Mar 8, Nov 1).
        XCTAssertEqual(tz.offset(atLocal: wall(2026, 3, 8, 1, 59)), -5 * 3600)
        XCTAssertEqual(tz.offset(atLocal: wall(2026, 3, 8, 3, 0)), -4 * 3600)
        XCTAssertEqual(tz.offset(atLocal: wall(2026, 11, 1, 0, 59)), -4 * 3600)
        XCTAssertEqual(tz.offset(atLocal: wall(2026, 11, 1, 2, 0)), -5 * 3600)
    }

    func testLastWeekdayRulesMatchTZDatabase() throws {
        let tz = try XCTUnwrap(zone("""
            BEGIN:DAYLIGHT
            DTSTART:19810329T020000
            TZOFFSETFROM:+0100
            TZOFFSETTO:+0200
            RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU
            END:DAYLIGHT
            BEGIN:STANDARD
            DTSTART:19961027T030000
            TZOFFSETFROM:+0200
            TZOFFSETTO:+0100
            RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU
            END:STANDARD
            """))
        assertMatches(tz, iana: "Europe/Berlin")
    }

    /// Daylight time spans the new year in the southern hemisphere.
    func testSouthernRulesMatchTZDatabase() throws {
        let tz = try XCTUnwrap(zone("""
            BEGIN:STANDARD
            DTSTART:20080406T030000
            TZOFFSETFROM:+1100
            TZOFFSETTO:+1000
            RRULE:FREQ=YEARLY;BYMONTH=4;BYDAY=1SU
            END:STANDARD
            BEGIN:DAYLIGHT
            DTSTART:20081005T020000
            TZOFFSETFROM:+1000
            TZOFFSETTO:+1100
            RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=1SU
            END:DAYLIGHT
            """))
        assertMatches(tz, iana: "Australia/Sydney")
    }

    /// Older Exchange form of "second Sunday in March".
    func testMonthDayListRuleMatchesTZDatabase() throws {
        let tz = try XCTUnwrap(zone("""
            BEGIN:STANDARD
            DTSTART:20071104T020000
            TZOFFSETFROM:-0700
            TZOFFSETTO:-0800
            RRULE:FREQ=YEARLY;BYMONTH=11;BYMONTHDAY=1,2,3,4,5,6,7;BYDAY=SU
            END:STANDARD
            BEGIN:DAYLIGHT
            DTSTART:20070311T020000
            TZOFFSETFROM:-0800
            TZOFFSETTO:-0700
            RRULE:FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=8,9,10,11,12,13,14;BYDAY=SU
            END:DAYLIGHT
            """))
        assertMatches(tz, iana: "America/Los_Angeles")
    }

    func testSingleOffsetNeedsNoRule() throws {
        let tz = try XCTUnwrap(zone("""
            BEGIN:STANDARD
            DTSTART:16010101T000000
            TZOFFSETFROM:+0800
            TZOFFSETTO:+0800
            END:STANDARD
            """))
        XCTAssertEqual(tz.offset(atLocal: wall(2026, 10, 5)), 8 * 3600)
        // Equal targets: an odd RRULE cannot change the answer.
        let odd = try XCTUnwrap(zone("""
            BEGIN:STANDARD
            DTSTART:16010101T000000
            TZOFFSETFROM:+0530
            TZOFFSETTO:+0530
            RRULE:FREQ=MONTHLY;BYSETPOS=2
            END:STANDARD
            BEGIN:DAYLIGHT
            DTSTART:16010101T000000
            TZOFFSETFROM:+0530
            TZOFFSETTO:+0530
            END:DAYLIGHT
            """))
        XCTAssertEqual(odd.offset(atLocal: wall(2026, 10, 5)), 5 * 3600 + 1800)
    }

    /// One-time transitions without RRULE (exporters that unroll the rules).
    func testOnsetsWithoutRuleAndRDATE() throws {
        let tz = try XCTUnwrap(zone("""
            BEGIN:DAYLIGHT
            DTSTART:20260308T020000
            TZOFFSETFROM:-0500
            TZOFFSETTO:-0400
            RDATE:20270314T020000
            END:DAYLIGHT
            BEGIN:STANDARD
            DTSTART:20261101T020000
            TZOFFSETFROM:-0400
            TZOFFSETTO:-0500
            END:STANDARD
            """))
        // Before the first onset: the earliest TZOFFSETFROM.
        XCTAssertEqual(tz.offset(atLocal: wall(2026, 2, 1)), -5 * 3600)
        XCTAssertEqual(tz.offset(atLocal: wall(2026, 7, 1)), -4 * 3600)
        XCTAssertEqual(tz.offset(atLocal: wall(2026, 12, 1)), -5 * 3600)
        XCTAssertEqual(tz.offset(atLocal: wall(2027, 7, 1)), -4 * 3600)
    }

    /// A rule that ended (UNTIL) still decides the offset after its last onset.
    func testUntilEndsARule() throws {
        let tz = try XCTUnwrap(zone("""
            BEGIN:DAYLIGHT
            DTSTART:20000326T020000
            TZOFFSETFROM:+0300
            TZOFFSETTO:+0400
            RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU;UNTIL=20100327T230000Z
            END:DAYLIGHT
            BEGIN:STANDARD
            DTSTART:20001029T030000
            TZOFFSETFROM:+0400
            TZOFFSETTO:+0300
            RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU;UNTIL=20101030T230000Z
            END:STANDARD
            """))
        XCTAssertEqual(tz.offset(atLocal: wall(2010, 7, 1)), 4 * 3600)
        // Summer 2026: no daylight onset since 2010, standard time holds.
        XCTAssertEqual(tz.offset(atLocal: wall(2026, 7, 1)), 3 * 3600)
        XCTAssertEqual(tz.offset(atLocal: wall(2026, 12, 1)), 3 * 3600)
    }

    /// Two offsets and a rule this parser does not model: no answer.
    func testUnsupportedRuleGivesNoOffset() throws {
        for rule in [
            "FREQ=YEARLY;BYMONTH=3;BYDAY=SU;BYSETPOS=2",
            "FREQ=MONTHLY;BYDAY=2SU",
            "FREQ=YEARLY;INTERVAL=2;BYMONTH=3;BYDAY=2SU",
            "FREQ=YEARLY;BYMONTH=3,4;BYDAY=2SU",
            "FREQ=YEARLY;BYDAY=2SU",
            "FREQ=YEARLY;BYMONTH=3;BYDAY=2SU;COUNT=5",
            "FREQ=YEARLY;BYMONTH=3;BYDAY=SU",
            "garbage",
        ] {
            let tz = try XCTUnwrap(zone("""
                BEGIN:STANDARD
                DTSTART:16010101T020000
                TZOFFSETFROM:-0400
                TZOFFSETTO:-0500
                RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=11
                END:STANDARD
                BEGIN:DAYLIGHT
                DTSTART:16010101T020000
                TZOFFSETFROM:-0500
                TZOFFSETTO:-0400
                RRULE:\(rule)
                END:DAYLIGHT
                """))
            XCTAssertNil(tz.offset(atLocal: wall(2026, 7, 1)), rule)
        }
    }

    func testMalformedBlocksAreRejected() {
        // No TZOFFSETTO.
        XCTAssertNil(zone("BEGIN:STANDARD\nDTSTART:16010101T000000\nEND:STANDARD"))
        // No observance.
        XCTAssertNil(zone("X-FOO:bar"))
        // A foreign component inside the block.
        XCTAssertNil(zone("""
            BEGIN:STANDARD
            DTSTART:16010101T000000
            TZOFFSETFROM:+0800
            TZOFFSETTO:+0800
            END:STANDARD
            BEGIN:VEVENT
            UID:smuggled
            END:VEVENT
            """))
    }

    func testParseOffset() {
        XCTAssertEqual(ICSTimeZone.parseOffset("+0800"), 28_800)
        XCTAssertEqual(ICSTimeZone.parseOffset("-0330"), -12_600)
        XCTAssertEqual(ICSTimeZone.parseOffset("+053015"), 19_815)
        XCTAssertNil(ICSTimeZone.parseOffset("0800"))
        XCTAssertNil(ICSTimeZone.parseOffset("+08"))
        XCTAssertNil(ICSTimeZone.parseOffset("+08:00"))
    }
}
