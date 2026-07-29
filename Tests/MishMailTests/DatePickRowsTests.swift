import XCTest

/// Pins the empty-query list shown the instant `b` opens the snooze picker.
/// The UI presents that list as a window overlay (not a modal sheet) so it
/// lands in the same frame as the keypress; these tests guard the pure data
/// that overlay renders on open.
final class DatePickRowsTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func testEmptyQueryMapsPresetsWithFormattedCaptions() {
        // Mid-morning: drops "This morning", keeps afternoon onward.
        let now = date(2026, 7, 16, 10, 0)
        let presets = SnoozePresets.presets(now: now, calendar: cal)
        XCTAssertFalse(presets.isEmpty)

        let rows = DatePickRows.rows(
            query: "",
            presets: presets.map { ($0.title, $0.date) },
            clearOption: nil,
            now: now
        )

        XCTAssertEqual(rows.map(\.title), presets.map(\.title))
        for (row, preset) in zip(rows, presets) {
            XCTAssertEqual(row.detail, SnoozeDateParser.format(preset.date))
            XCTAssertEqual(row.action, .some(preset.date))
        }
        // First row is the soonest useful wake — the thing users hit Return on.
        XCTAssertEqual(rows.first?.title, "This afternoon")
    }

    func testEmptyQueryWhitespaceStillShowsPresets() {
        let now = date(2026, 7, 16, 10, 0)
        let presets = SnoozePresets.presets(now: now, calendar: cal)
        let rows = DatePickRows.rows(
            query: "   ",
            presets: presets.map { ($0.title, $0.date) },
            clearOption: nil,
            now: now
        )
        XCTAssertEqual(rows.count, presets.count)
    }

    func testClearOptionAppendedForAlreadySnoozed() {
        let now = date(2026, 7, 16, 10, 0)
        let presets = SnoozePresets.presets(now: now, calendar: cal)
        let rows = DatePickRows.rows(
            query: "",
            presets: presets.map { ($0.title, $0.date) },
            clearOption: ("Unsnooze", "back to inbox"),
            now: now
        )
        XCTAssertEqual(rows.count, presets.count + 1)
        let clear = rows.last
        XCTAssertEqual(clear?.title, "Unsnooze")
        XCTAssertEqual(clear?.detail, "back to inbox")
        XCTAssertEqual(clear?.action, .some(nil))
    }

    func testTypedQueryUsesParserNotPresets() {
        let now = date(2026, 7, 16, 10, 0)
        let presets = SnoozePresets.presets(now: now, calendar: cal)
        let rows = DatePickRows.rows(
            query: "tomorrow",
            presets: presets.map { ($0.title, $0.date) },
            clearOption: nil,
            now: now
        )
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.title.localizedCaseInsensitiveContains("tomorrow")
            || $0.detail.localizedCaseInsensitiveContains("tomorrow") })
        // Preset-only titles like "This afternoon" must not appear.
        XCTAssertFalse(rows.contains { $0.title == "This afternoon" })
    }

    func testMinDateFiltersPastSuggestions() {
        // 3pm is still ahead at 10am; filter it out with minDate in the future.
        let now = date(2026, 7, 16, 10, 0)
        let min = date(2026, 7, 16, 16, 0)
        let rows = DatePickRows.rows(
            query: "3pm",
            presets: [],
            clearOption: nil,
            minDate: min,
            now: now
        )
        // "Today 3pm" is before minDate → dropped; tomorrow 3pm may remain.
        for row in rows {
            if case let .some(.some(date)) = row.action {
                XCTAssertGreaterThan(date, min)
            }
        }
    }
}
