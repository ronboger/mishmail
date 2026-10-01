import Foundation

/// One `VTIMEZONE` block from an ICS document (RFC 5545 §3.6.5), used only
/// when the event's TZID is neither an IANA id nor a known Windows name.
///
/// `offset(atLocal:)` answers "what UTC offset is in effect at this wall
/// time" or nil. It never guesses: a rule shape it does not fully understand
/// gives nil, and the caller then shows the raw time instead of a wrong one.
struct ICSTimeZone: Equatable, Sendable {
    /// A STANDARD or DAYLIGHT sub-component.
    struct Observance: Equatable, Sendable {
        /// First onset as wall time (seconds since 1970 read as if UTC).
        var start: TimeInterval?
        /// Seconds east of UTC before / after the onset.
        var offsetFrom: Int?
        var offsetTo: Int
        var rule: Rule?
        /// Extra onsets from RDATE, same wall-time encoding as `start`.
        var extraOnsets: [TimeInterval] = []
        /// False when the block had a property this parser cannot evaluate
        /// (malformed RRULE, RDATE with a PERIOD, …).
        var supported = true
    }

    /// The yearly RRULE shapes that real VTIMEZONE blocks use.
    struct Rule: Equatable, Sendable {
        var month: Int
        var day: Day
        /// Last valid onset. `untilIsUTC` says how to compare it.
        var until: TimeInterval?
        var untilIsUTC = false

        enum Day: Equatable, Sendable {
            /// `BYDAY=2SU` / `BYDAY=-1SU`: nth weekday of the month
            /// (weekday 1 = Sunday; ordinal is never 0).
            case nthWeekday(ordinal: Int, weekday: Int)
            /// `BYMONTHDAY=8,9,…,14;BYDAY=SU`: the listed day that falls on
            /// the weekday (older Exchange form of "second Sunday").
            case weekdayAmong(days: [Int], weekday: Int)
            /// `BYMONTHDAY=25`, or DTSTART's own day when the rule names none.
            case monthDay(Int)
        }
    }

    var tzid: String
    var observances: [Observance]
    /// Unfolded source lines, `BEGIN:VTIMEZONE` … `END:VTIMEZONE`.
    var lines: [String]

    // MARK: - Parse

    /// Every well-formed VTIMEZONE in the unfolded lines, keyed by TZID
    /// (first block wins on a duplicate id).
    static func parseAll(_ lines: [String]) -> [String: ICSTimeZone] {
        var out: [String: ICSTimeZone] = [:]
        var block: [String]?
        for line in lines {
            let upper = line.uppercased()
            if upper.hasPrefix("BEGIN:VTIMEZONE") {
                block = [line]
                continue
            }
            guard block != nil else { continue }
            block?.append(line)
            if upper.hasPrefix("END:VTIMEZONE") {
                if let zone = parseBlock(block ?? []), out[zone.tzid] == nil {
                    out[zone.tzid] = zone
                }
                block = nil
            } else if (block?.count ?? 0) > maxBlockLines {
                block = nil
            }
        }
        return out
    }

    /// A zone with an observance per year (some exporters unroll the rules)
    /// stays far below this; anything larger is not a real VTIMEZONE.
    private static let maxBlockLines = 2_000

    private static func parseBlock(_ lines: [String]) -> ICSTimeZone? {
        var tzid = ""
        var observances: [Observance] = []
        var current: [(name: String, params: [String: String], value: String)]?
        for line in lines.dropFirst().dropLast() {
            let upper = line.uppercased()
            if upper.hasPrefix("BEGIN:") {
                // Only STANDARD / DAYLIGHT may nest, and not inside each other.
                guard current == nil,
                      upper == "BEGIN:STANDARD" || upper == "BEGIN:DAYLIGHT"
                else { return nil }
                current = []
                continue
            }
            if upper.hasPrefix("END:") {
                guard let props = current,
                      upper == "END:STANDARD" || upper == "END:DAYLIGHT",
                      let obs = observance(from: props) else { return nil }
                observances.append(obs)
                current = nil
                continue
            }
            guard let prop = CalendarInvite.splitProperty(line) else { continue }
            if current != nil {
                current?.append(prop)
            } else if prop.name == "TZID", tzid.isEmpty {
                tzid = prop.value.trimmingCharacters(in: .whitespaces)
            }
        }
        guard current == nil, !tzid.isEmpty, !observances.isEmpty else { return nil }
        return ICSTimeZone(tzid: tzid, observances: observances, lines: lines)
    }

    private static func observance(
        from props: [(name: String, params: [String: String], value: String)]
    ) -> Observance? {
        var start: TimeInterval?
        var from: Int?
        var to: Int?
        var ruleText: String?
        var extra: [TimeInterval] = []
        var supported = true
        for prop in props {
            let value = prop.value.trimmingCharacters(in: .whitespaces)
            switch prop.name {
            case "DTSTART":
                start = wallTime(value)?.time
                if start == nil { supported = false }
            case "TZOFFSETFROM":
                from = parseOffset(value)
            case "TZOFFSETTO":
                to = parseOffset(value)
            case "RRULE":
                // Two RRULEs in one observance: not a shape we evaluate.
                if ruleText != nil { supported = false }
                ruleText = value
            case "RDATE":
                for item in value.split(separator: ",") {
                    if let t = wallTime(String(item))?.time {
                        extra.append(t)
                    } else {
                        supported = false
                    }
                }
            default:
                break
            }
        }
        guard let to else { return nil }
        var obs = Observance(start: start, offsetFrom: from, offsetTo: to,
                             extraOnsets: extra, supported: supported)
        if let ruleText {
            if let start, let rule = parseRule(ruleText, start: start) {
                obs.rule = rule
            } else {
                obs.supported = false
            }
        }
        return obs
    }

    /// `+0800`, `-0330`, `+053000` → seconds east of UTC.
    static func parseOffset(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard let signChar = s.first, signChar == "+" || signChar == "-" else { return nil }
        let digits = s.dropFirst()
        guard digits.count == 4 || digits.count == 6,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let h = Int(digits.prefix(2)),
              let m = Int(digits.dropFirst(2).prefix(2)),
              h <= 23, m <= 59 else { return nil }
        let sec = digits.count == 6 ? (Int(digits.suffix(2)) ?? 0) : 0
        guard sec <= 59 else { return nil }
        let total = h * 3600 + m * 60 + sec
        return signChar == "-" ? -total : total
    }

    /// Parse one RRULE. Nil for every shape outside `Rule.Day`: a wrong
    /// transition date would shift the event by an hour without any sign.
    private static func parseRule(_ raw: String, start: TimeInterval) -> Rule? {
        var parts: [String: String] = [:]
        for seg in raw.split(separator: ";") {
            guard let eq = seg.firstIndex(of: "=") else { return nil }
            let key = seg[..<eq].trimmingCharacters(in: .whitespaces).uppercased()
            let val = seg[seg.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces).uppercased()
            guard parts[key] == nil else { return nil }
            parts[key] = val
        }
        let known: Set<String> = [
            "FREQ", "INTERVAL", "BYMONTH", "BYDAY", "BYMONTHDAY", "UNTIL", "WKST",
        ]
        guard Set(parts.keys).isSubset(of: known),
              parts["FREQ"] == "YEARLY",
              (parts["INTERVAL"] ?? "1") == "1" else { return nil }

        let startParts = utcCalendar.dateComponents(
            [.month, .day], from: Date(timeIntervalSince1970: start))
        guard let startMonth = startParts.month, let startDay = startParts.day
        else { return nil }

        let byDay = parts["BYDAY"]
        let byMonthDay = parts["BYMONTHDAY"]
        let month: Int
        if let raw = parts["BYMONTH"] {
            guard let m = Int(raw), (1...12).contains(m) else { return nil }
            month = m
        } else {
            // Without BYMONTH, BYDAY / BYMONTHDAY mean "of the year" or
            // "every month" — not a yearly transition we can place.
            guard byDay == nil, byMonthDay == nil else { return nil }
            month = startMonth
        }

        var monthDays: [Int] = []
        if let byMonthDay {
            for item in byMonthDay.split(separator: ",") {
                guard let d = Int(item), d != 0, (-31...31).contains(d) else { return nil }
                monthDays.append(d)
            }
            guard !monthDays.isEmpty else { return nil }
        }

        let day: Rule.Day
        if let byDay {
            guard !byDay.contains(","), byDay.count >= 2,
                  let weekday = weekdayCodes[String(byDay.suffix(2))] else { return nil }
            let ordinalText = String(byDay.dropLast(2))
            if ordinalText.isEmpty {
                guard !monthDays.isEmpty else { return nil }
                day = .weekdayAmong(days: monthDays, weekday: weekday)
            } else {
                guard monthDays.isEmpty, let ordinal = Int(ordinalText),
                      ordinal != 0, (-5...5).contains(ordinal) else { return nil }
                day = .nthWeekday(ordinal: ordinal, weekday: weekday)
            }
        } else if monthDays.count == 1 {
            day = .monthDay(monthDays[0])
        } else if monthDays.isEmpty {
            day = .monthDay(startDay)
        } else {
            return nil
        }

        var rule = Rule(month: month, day: day)
        if let untilRaw = parts["UNTIL"] {
            if untilRaw.count == 8, let dayStart = wallTime(untilRaw + "T235959") {
                rule.until = dayStart.time
            } else if let until = wallTime(untilRaw) {
                rule.until = until.time
                rule.untilIsUTC = until.isUTC
            } else {
                return nil
            }
        }
        return rule
    }

    private static let weekdayCodes: [String: Int] = [
        "SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7,
    ]

    // MARK: - Evaluate

    /// UTC offset (seconds east) in effect at a wall time in this zone, or
    /// nil when the block does not say unambiguously.
    ///
    /// Wall times are compared with wall times, as RFC 5545 defines onsets.
    /// Inside the repeated hour at the end of daylight time the later
    /// (standard) offset is used.
    func offset(atLocal wall: TimeInterval) -> Int? {
        guard !observances.isEmpty else { return nil }
        // One offset all year: no rule evaluation needed.
        let targets = Set(observances.map(\.offsetTo))
        if targets.count == 1 { return targets.first }

        var best: (onset: TimeInterval, offset: Int)?
        var earliest: (start: TimeInterval, from: Int?)?
        for obs in observances {
            guard obs.supported, let start = obs.start else { return nil }
            if earliest == nil || start < earliest!.start {
                earliest = (start, obs.offsetFrom)
            }
            guard let onset = obs.lastOnset(notAfter: wall) else { continue }
            if best == nil || onset > best!.onset {
                best = (onset, obs.offsetTo)
            }
        }
        if let best { return best.offset }
        // Before the first onset the zone is at the earliest TZOFFSETFROM.
        return earliest?.from
    }

    static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    /// `YYYYMMDDTHHMMSS[Z]` → seconds since 1970 with the fields read as UTC.
    static func wallTime(_ raw: String) -> (time: TimeInterval, isUTC: Bool)? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let isUTC = value.hasSuffix("Z") || value.hasSuffix("z")
        let core = isUTC ? String(value.dropLast()) : value
        let chars = Array(core)
        guard chars.count == 15, chars[8] == "T" || chars[8] == "t" else { return nil }
        func num(_ range: Range<Int>) -> Int? {
            let slice = chars[range]
            guard slice.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(String(slice))
        }
        guard let y = num(0..<4), let mo = num(4..<6), let d = num(6..<8),
              let h = num(9..<11), let mi = num(11..<13), let s = num(13..<15),
              let time = wallTime(year: y, month: mo, day: d,
                                  hour: h, minute: mi, second: s)
        else { return nil }
        return (time, isUTC)
    }

    /// Nil for a date that does not exist (Feb 30, hour 25) — Calendar would
    /// otherwise roll it over into the next month.
    static func wallTime(year: Int, month: Int, day: Int,
                         hour: Int, minute: Int, second: Int) -> TimeInterval? {
        guard (1...12).contains(month), day >= 1,
              (0...23).contains(hour), (0...59).contains(minute),
              (0...60).contains(second),
              let first = utcCalendar.date(
                from: DateComponents(year: year, month: month, day: 1)),
              let dayCount = utcCalendar.range(of: .day, in: .month, for: first)?.count,
              day <= dayCount else { return nil }
        return first.timeIntervalSince1970
            + Double((day - 1) * 86_400 + hour * 3_600 + minute * 60 + second)
    }
}

extension ICSTimeZone.Observance {
    /// Latest onset of this observance at or before `wall`, or nil when it
    /// has not started yet.
    func lastOnset(notAfter wall: TimeInterval) -> TimeInterval? {
        guard let start else { return nil }
        var candidates = [start] + extraOnsets
        if let rule {
            let cal = ICSTimeZone.utcCalendar
            let wallYear = cal.component(.year, from: Date(timeIntervalSince1970: wall))
            var years: Set<Int> = [wallYear, wallYear - 1]
            if let until = rule.until {
                // A rule that ended years ago still set the offset in force.
                let untilYear = cal.component(
                    .year, from: Date(timeIntervalSince1970: until))
                years.formUnion([untilYear, untilYear - 1])
            }
            let secondsIntoDay = start - (start / 86_400).rounded(.down) * 86_400
            for year in years {
                guard let day = rule.dayOfMonth(year: year),
                      let midnight = ICSTimeZone.wallTime(
                        year: year, month: rule.month, day: day,
                        hour: 0, minute: 0, second: 0) else { continue }
                let onset = midnight + secondsIntoDay
                guard onset >= start else { continue }
                if let until = rule.until {
                    // UNTIL in UTC is compared with the onset in UTC, which
                    // is the wall time minus the offset before the change.
                    let comparable = rule.untilIsUTC
                        ? onset - Double(offsetFrom ?? offsetTo) : onset
                    guard comparable <= until else { continue }
                }
                candidates.append(onset)
            }
        }
        return candidates.filter { $0 <= wall }.max()
    }
}

extension ICSTimeZone.Rule {
    /// Day of the month the rule selects in `year`, or nil when that year
    /// has none (a fifth Sunday that does not exist, Feb 29).
    func dayOfMonth(year: Int) -> Int? {
        let cal = ICSTimeZone.utcCalendar
        guard let first = cal.date(
                from: DateComponents(year: year, month: month, day: 1)),
              let dayCount = cal.range(of: .day, in: .month, for: first)?.count
        else { return nil }
        let firstWeekday = cal.component(.weekday, from: first)
        func weekday(of day: Int) -> Int { (firstWeekday - 1 + day - 1) % 7 + 1 }
        func resolve(_ day: Int) -> Int? {
            let d = day > 0 ? day : dayCount + 1 + day
            return (1...dayCount).contains(d) ? d : nil
        }
        switch day {
        case .monthDay(let d):
            return resolve(d)
        case .weekdayAmong(let days, let wd):
            return days.compactMap(resolve).sorted().first { weekday(of: $0) == wd }
        case .nthWeekday(let ordinal, let wd):
            let matches = (1...dayCount).filter { weekday(of: $0) == wd }
            let index = ordinal > 0 ? ordinal - 1 : matches.count + ordinal
            return matches.indices.contains(index) ? matches[index] : nil
        }
    }
}
