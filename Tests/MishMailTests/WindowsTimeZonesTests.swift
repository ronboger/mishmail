import XCTest

final class WindowsTimeZonesTests: XCTestCase {

    /// A typo in any IANA id must fail here, not show a wrong meeting time.
    func testEveryMappedIdentifierResolves() {
        XCTAssertGreaterThan(WindowsTimeZones.table.count, 130)
        for (windows, iana) in WindowsTimeZones.table {
            XCTAssertNotNil(TimeZone(identifier: iana),
                            "\(windows) maps to unknown id \(iana)")
            XCTAssertFalse(windows.isEmpty)
            XCTAssertEqual(windows, windows.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Guards against a valid-but-wrong id: the zone's January and July
    /// offsets (hours east of UTC) in 2026 must match the Windows zone.
    func testOffsetsOfCommonZones() {
        let expected: [(String, Double, Double)] = [
            ("Dateline Standard Time", -12, -12),
            ("Hawaiian Standard Time", -10, -10),
            ("Alaskan Standard Time", -9, -8),
            ("Pacific Standard Time", -8, -7),
            ("US Mountain Standard Time", -7, -7),
            ("Mountain Standard Time", -7, -6),
            ("Central Standard Time", -6, -5),
            ("Central Standard Time (Mexico)", -6, -6),
            ("Canada Central Standard Time", -6, -6),
            ("SA Pacific Standard Time", -5, -5),
            ("Eastern Standard Time", -5, -4),
            ("US Eastern Standard Time", -5, -4),
            ("Atlantic Standard Time", -4, -3),
            ("Newfoundland Standard Time", -3.5, -2.5),
            ("E. South America Standard Time", -3, -3),
            ("Argentina Standard Time", -3, -3),
            ("UTC-02", -2, -2),
            ("UTC", 0, 0),
            ("GMT Standard Time", 0, 1),
            ("Greenwich Standard Time", 0, 0),
            ("W. Europe Standard Time", 1, 2),
            ("Central Europe Standard Time", 1, 2),
            ("Central European Standard Time", 1, 2),
            ("Romance Standard Time", 1, 2),
            ("GTB Standard Time", 2, 3),
            ("FLE Standard Time", 2, 3),
            ("E. Europe Standard Time", 2, 3),
            ("Israel Standard Time", 2, 3),
            ("South Africa Standard Time", 2, 2),
            ("Turkey Standard Time", 3, 3),
            ("Arab Standard Time", 3, 3),
            ("Russian Standard Time", 3, 3),
            ("Iran Standard Time", 3.5, 3.5),
            ("Arabian Standard Time", 4, 4),
            ("Pakistan Standard Time", 5, 5),
            ("India Standard Time", 5.5, 5.5),
            ("Nepal Standard Time", 5.75, 5.75),
            ("Central Asia Standard Time", 6, 6),
            ("SE Asia Standard Time", 7, 7),
            ("China Standard Time", 8, 8),
            ("Singapore Standard Time", 8, 8),
            ("W. Australia Standard Time", 8, 8),
            ("Taipei Standard Time", 8, 8),
            ("Tokyo Standard Time", 9, 9),
            ("Korea Standard Time", 9, 9),
            ("Cen. Australia Standard Time", 10.5, 9.5),
            ("AUS Central Standard Time", 9.5, 9.5),
            ("E. Australia Standard Time", 10, 10),
            ("AUS Eastern Standard Time", 11, 10),
            ("Tasmania Standard Time", 11, 10),
            ("Central Pacific Standard Time", 11, 11),
            ("New Zealand Standard Time", 13, 12),
            ("UTC+12", 12, 12),
            ("Tonga Standard Time", 13, 13),
            ("Line Islands Standard Time", 14, 14),
        ]
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let january = cal.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 12))!
        let july = cal.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 12))!
        for (windows, jan, jul) in expected {
            guard let iana = WindowsTimeZones.ianaIdentifier(for: windows),
                  let tz = TimeZone(identifier: iana) else {
                XCTFail("\(windows) does not resolve")
                continue
            }
            XCTAssertEqual(Double(tz.secondsFromGMT(for: january)) / 3600, jan,
                           "\(windows) January")
            XCTAssertEqual(Double(tz.secondsFromGMT(for: july)) / 3600, jul,
                           "\(windows) July")
        }
    }

    func testLookupIsCaseInsensitiveAndRejectsUnknown() {
        XCTAssertEqual(WindowsTimeZones.ianaIdentifier(for: "singapore standard time"),
                       "Asia/Singapore")
        XCTAssertNil(WindowsTimeZones.ianaIdentifier(for: "Totally Fake Zone"))
    }
}
