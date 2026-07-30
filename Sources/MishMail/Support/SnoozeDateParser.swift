import Foundation

/// Notion-style natural-language date suggestions for the snooze picker.
/// Turns partial input like "tom", "fri 3pm", "in 2 weeks", "aug 12" into
/// concrete future dates, prefix-matching so suggestions appear as you type.
enum SnoozeDateParser {
    struct Suggestion: Equatable, Identifiable {
        let label: String
        let date: Date
        var id: String { label }
    }

    static func suggestions(for query: String, now: Date = Date()) -> [Suggestion] {
        let cal = Calendar.current
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return [] }

        var (datePart, time) = splitTime(from: text)
        var results: [Suggestion] = []

        // A bare trailing number after a date *word* is a 24h hour:
        // "tm 10" → tomorrow 10:00, "fri 20" → Friday 20:00. Guarded to
        // date words only so "aug 12" keeps 12 as the day, not the hour.
        if time == nil, let m = datePart.wholeMatch(of: /(.+) (\d{1,2})/) {
            let hour = Int(m.2)!
            if hour < 24, Self.isDateWord(String(m.1), calendar: cal) {
                datePart = String(m.1)
                time = (hour, 0)
            }
        }

        func at(_ day: Date, _ fallbackHour: Int = 8) -> Date? {
            let h = time?.hour ?? fallbackHour
            let m = time?.minute ?? 0
            return cal.date(bySettingHour: h, minute: m, second: 0, of: day)
        }
        func add(_ name: String, _ date: Date?) {
            guard let date, date > now, !results.contains(where: { $0.date == date }) else { return }
            results.append(Suggestion(label: "\(name)  ·  \(Self.format(date))", date: date))
        }
        func nextWeekday(_ weekday: Int) -> Date {
            cal.nextDate(after: now, matching: DateComponents(weekday: weekday),
                         matchingPolicy: .nextTime)!
        }
        func addHours(_ n: Int) -> Date? {
            cal.date(byAdding: .hour, value: n, to: now)
        }
        func addDays(_ n: Int, hour: Int = 8) -> Date? {
            guard let day = cal.date(byAdding: .day, value: n, to: now) else { return nil }
            return at(day, hour)
        }
        /// Soonest useful "later today": afternoon if still ahead, else evening,
        /// else tomorrow morning (nothing left in the day).
        func laterToday() -> Date? {
            let afternoon = at(now, SnoozePresets.afternoonHour)
            if let afternoon, afternoon > now { return afternoon }
            let evening = at(now, SnoozePresets.eveningHour)
            if let evening, evening > now { return evening }
            return addDays(1, hour: SnoozePresets.morningHour)
        }
        func endOfDay() -> Date? {
            let evening = at(now, SnoozePresets.eveningHour)
            if let evening, evening > now { return evening }
            return addDays(1, hour: SnoozePresets.eveningHour)
        }
        func endOfWeek() -> Date? {
            // Friday evening this week if still ahead; otherwise next Friday.
            let weekday = cal.component(.weekday, from: now)
            if weekday == 6, // Friday
               let evening = at(now, SnoozePresets.eveningHour), evening > now {
                return evening
            }
            return at(nextWeekday(6), SnoozePresets.eveningHour)
        }
        func endOfMonth() -> Date? {
            let dayRange = cal.range(of: .day, in: .month, for: now)!
            var comps = cal.dateComponents([.year, .month], from: now)
            comps.day = dayRange.count
            guard let last = cal.date(from: comps), let dated = at(last) else { return nil }
            if dated > now { return dated }
            // Already past this month's end → last day of next month.
            guard let nextMonth = cal.date(byAdding: .month, value: 1, to: last) else { return nil }
            let nextRange = cal.range(of: .day, in: .month, for: nextMonth)!
            var nextComps = cal.dateComponents([.year, .month], from: nextMonth)
            nextComps.day = nextRange.count
            return cal.date(from: nextComps).flatMap { at($0) }
        }

        // Bare time ("3pm", "at 17:30", bare "morning") → today, or tomorrow if past.
        if datePart.isEmpty, time != nil {
            let today = at(now)
            add("Today", today)
            if let today, today <= now {
                add("Tomorrow", at(cal.date(byAdding: .day, value: 1, to: now)!))
            }
        }

        // Keywords, prefix-matched (and aliases that don't share a prefix).
        let keywords: [(String, () -> Date?)] = [
            ("today", { at(now) }),
            ("tonight", { at(now, 20) }),
            ("tomorrow", { addDays(1) }),
            ("later today", { laterToday() }),
            ("later", { laterToday() }),
            ("next week", { at(nextWeekday(2)) }),          // Monday
            ("next month", {
                let comps = cal.dateComponents([.year, .month], from: cal.date(byAdding: .month, value: 1, to: now)!)
                return at(cal.date(from: comps)!)
            }),
            ("weekend", { at(nextWeekday(7)) }),            // Saturday
            ("this weekend", { at(nextWeekday(7)) }),
            ("end of day", { endOfDay() }),
            ("end of week", { endOfWeek() }),
            ("end of month", { endOfMonth() }),
        ]
        let aliases: [String: [String]] = [
            "tomorrow": ["tm", "tmr", "tmrw", "tmw", "tmo", "tmoro"],
            "today": ["td", "tdy"],
            "tonight": ["tn", "tnt"],
            "later today": ["lt"],
            "later": ["l8r"],
            "end of day": ["eod"],
            "end of week": ["eow"],
            "end of month": ["eom"],
            "weekend": ["wknd"],
            "next week": ["nw"],
            "next month": ["nm"],
        ]
        func matchesKeyword(_ word: String) -> Bool {
            word.hasPrefix(datePart) || (aliases[word]?.contains(datePart) ?? false)
        }
        for (word, make) in keywords where matchesKeyword(word) {
            // "later" and "later today" share a date — prefer the longer label
            // when both match (e.g. "lat" / "later").
            let title: String = {
                switch word {
                case "later": return "Later today"
                case "end of day", "end of week", "end of month":
                    return word.split(separator: " ").map(\.capitalized).joined(separator: " ")
                default:
                    return word.capitalized
                }
            }()
            add(title, make())
        }

        // Weekday names, prefix-matched from the first character ("s" →
        // Saturday/Sunday, "fri" → Friday).
        let symbols = cal.weekdaySymbols  // Sunday-first
        for (i, name) in symbols.enumerated() where name.lowercased().hasPrefix(datePart) {
            add(name, at(nextWeekday(i + 1)))
        }

        // Relative durations: "in 2 weeks", "2 days", "3h", "in 1 h", and
        // bare unit prefixes ("hour" → in 1 hour) so single-letter typing
        // surfaces something useful for h/d/w and partial "in".
        addRelativeSuggestions(
            text: text, datePart: datePart, now: now, calendar: cal,
            add: add, at: at, addHours: addHours, addDays: addDays
        )

        // "aug 12" / "12 aug" / "8/12", each optionally with a year
        // ("aug 17 2027", "8/12/27"). Without a year we roll to next year
        // if the date has already passed.
        let months = cal.monthSymbols.map { $0.lowercased() }
        func monthDay(month: Int, day: Int, year: Int? = nil) -> Date? {
            if let year {
                return cal.date(from: DateComponents(year: year, month: month, day: day)).flatMap { at($0) }
            }
            var comps = DateComponents(year: cal.component(.year, from: now), month: month, day: day)
            guard let d = cal.date(from: comps) else { return nil }
            if let dated = at(d), dated > now { return dated }
            comps.year! += 1
            return cal.date(from: comps).flatMap { at($0) }
        }
        func label(month: Int, day: Int, year: Int?) -> String {
            let base = "\(cal.monthSymbols[month]) \(day)"
            return year.map { "\(base), \($0)" } ?? base
        }
        func fullYear(_ raw: Int?) -> Int? {
            guard let raw else { return nil }
            return raw < 100 ? 2000 + raw : raw
        }
        if let m = datePart.wholeMatch(of: /([a-z]{3,}) (\d{1,2})(?:,? (\d{2,4}))?/),
           let month = months.firstIndex(where: { $0.hasPrefix(String(m.1)) }) {
            let year = fullYear(m.3.flatMap { Int($0) })
            add(label(month: month, day: Int(m.2)!, year: year),
                monthDay(month: month + 1, day: Int(m.2)!, year: year))
        } else if let m = datePart.wholeMatch(of: /(\d{1,2}) ([a-z]{3,})(?:,? (\d{2,4}))?/),
                  let month = months.firstIndex(where: { $0.hasPrefix(String(m.2)) }) {
            let year = fullYear(m.3.flatMap { Int($0) })
            add(label(month: month, day: Int(m.1)!, year: year),
                monthDay(month: month + 1, day: Int(m.1)!, year: year))
        } else if let m = datePart.wholeMatch(of: /(\d{1,2})\/(\d{1,2})(?:\/(\d{2,4}))?/) {
            let year = fullYear(m.3.flatMap { Int($0) })
            add(label(month: Int(m.1)! - 1, day: Int(m.2)!, year: year),
                monthDay(month: Int(m.1)!, day: Int(m.2)!, year: year))
        } else if datePart.wholeMatch(of: /[a-z]+/) != nil {
            // Bare month ("s", "sep", "september") → 1st of that month at 8am
            // (rolls to next year when the 1st has already passed). Digits /
            // spaces above keep "aug 12" on the day path.
            for (i, name) in months.enumerated() where name.hasPrefix(datePart) {
                add(cal.monthSymbols[i], monthDay(month: i + 1, day: 1))
            }
        }

        return Array(results.prefix(5))
    }

    /// Relative-duration suggestions: full "in 2 weeks", compact "3h"/"2d"/"1w",
    /// unit prefixes ("hour"), and an incomplete "in" / "in 2" ladder so the
    /// first keystrokes after `b` still show something useful.
    private static func addRelativeSuggestions(
        text: String,
        datePart: String,
        now: Date,
        calendar cal: Calendar,
        add: (String, Date?) -> Void,
        at: (Date, Int) -> Date?,
        addHours: (Int) -> Date?,
        addDays: (Int, Int) -> Date?
    ) {
        // Compact: "2h", "3d", "1w", "2mo" (mo = month; bare "m" stays month-name).
        if let m = text.wholeMatch(of: /(\d+)\s*(h|hr|hrs|d|w|wk|wks|mo)s?/) {
            let n = Int(m.1)!
            switch String(m.2) {
            case "h", "hr", "hrs":
                add("In \(n) hour\(n == 1 ? "" : "s")", addHours(n))
            case "d":
                add("In \(n) day\(n == 1 ? "" : "s")", addDays(n, 8))
            case "w", "wk", "wks":
                add("In \(n) week\(n == 1 ? "" : "s")",
                    cal.date(byAdding: .weekOfYear, value: n, to: now).flatMap { at($0, 8) })
            case "mo":
                add("In \(n) month\(n == 1 ? "" : "s")",
                    cal.date(byAdding: .month, value: n, to: now).flatMap { at($0, 8) })
            default: break
            }
        }

        // "in 2 weeks" / "2 days" / "in 2 da" (unit prefix-matched).
        if let m = text.wholeMatch(of: /(?:in )?(\d+)\s*([a-z]*)/),
           let unit = resolveUnitPrefix(String(m.2)), !String(m.2).isEmpty {
            let n = Int(m.1)!
            switch unit {
            case .hour:
                add("In \(n) hour\(n == 1 ? "" : "s")", addHours(n))
            case .day:
                add("In \(n) day\(n == 1 ? "" : "s")", addDays(n, 8))
            case .week:
                add("In \(n) week\(n == 1 ? "" : "s")",
                    cal.date(byAdding: .weekOfYear, value: n, to: now).flatMap { at($0, 8) })
            case .month:
                add("In \(n) month\(n == 1 ? "" : "s")",
                    cal.date(byAdding: .month, value: n, to: now).flatMap { at($0, 8) })
            }
        }

        // "in 2" with no unit yet → offer each unit for that N.
        if let m = text.wholeMatch(of: /in (\d+)\s*/), Int(m.1) != nil {
            let n = Int(m.1)!
            add("In \(n) hour\(n == 1 ? "" : "s")", addHours(n))
            add("In \(n) day\(n == 1 ? "" : "s")", addDays(n, 8))
            add("In \(n) week\(n == 1 ? "" : "s")",
                cal.date(byAdding: .weekOfYear, value: n, to: now).flatMap { at($0, 8) })
            add("In \(n) month\(n == 1 ? "" : "s")",
                cal.date(byAdding: .month, value: n, to: now).flatMap { at($0, 8) })
        }

        // Bare "in" / "i" (prefix of "in") → common relative ladder.
        if "in".hasPrefix(datePart), datePart.count <= 2, !datePart.isEmpty,
           datePart.wholeMatch(of: /[a-z]+/) != nil,
           // Don't steal "i" once a longer non-in token is underway.
           text == datePart {
            add("In 1 hour", addHours(1))
            add("In 1 day", addDays(1, 8))
            add("In 3 days", addDays(3, 8))
            add("In 1 week",
                cal.date(byAdding: .weekOfYear, value: 1, to: now).flatMap { at($0, 8) })
            add("In 1 month",
                cal.date(byAdding: .month, value: 1, to: now).flatMap { at($0, 8) })
        }

        // Bare unit words ("hour", "day", "week", "month") → in 1 <unit>.
        // Single-letter: h→hour, d also hits December (both useful).
        if datePart.wholeMatch(of: /[a-z]+/) != nil {
            if unitWord("hour", matches: datePart) || unitWord("hours", matches: datePart) {
                add("In 1 hour", addHours(1))
            }
            if unitWord("day", matches: datePart) || unitWord("days", matches: datePart) {
                add("In 1 day", addDays(1, 8))
            }
            if unitWord("week", matches: datePart) || unitWord("weeks", matches: datePart) {
                add("In 1 week",
                    cal.date(byAdding: .weekOfYear, value: 1, to: now).flatMap { at($0, 8) })
            }
            if unitWord("month", matches: datePart) || unitWord("months", matches: datePart) {
                add("In 1 month",
                    cal.date(byAdding: .month, value: 1, to: now).flatMap { at($0, 8) })
            }
        }
    }

    private enum RelativeUnit { case hour, day, week, month }

    private static func resolveUnitPrefix(_ prefix: String) -> RelativeUnit? {
        guard !prefix.isEmpty else { return nil }
        // Longest-first so "mo" → month not a false "m" minute.
        let table: [(RelativeUnit, [String])] = [
            (.hour, ["hour", "hours", "hr", "hrs", "h"]),
            (.day, ["day", "days", "d"]),
            (.week, ["week", "weeks", "wk", "wks", "w"]),
            (.month, ["month", "months", "mo"]),
        ]
        for (unit, names) in table where names.contains(where: { $0.hasPrefix(prefix) && prefix.count <= $0.count }) {
            // Require the typed prefix to be a prefix of the unit name (not
            // the other way: "months".hasPrefix("mo") is checked via name).
            if names.contains(where: { $0.hasPrefix(prefix) }) { return unit }
        }
        return nil
    }

    private static func unitWord(_ word: String, matches prefix: String) -> Bool {
        word.hasPrefix(prefix)
    }

    /// Peels a trailing time expression off the query:
    /// "fri 3pm" → ("fri", 15:00), "aug 12 at 17:30" → ("aug 12", 17:30).
    private static func splitTime(from text: String) -> (String, (hour: Int, minute: Int)?) {
        let wordTimes: [String: Int] = ["noon": 12, "morning": 8, "afternoon": 14, "evening": 18, "night": 20]
        for (word, hour) in wordTimes where text.hasSuffix(word) {
            let rest = String(text.dropLast(word.count))
                .trimmingCharacters(in: .whitespaces)
            let cleaned = rest.hasSuffix(" at") ? String(rest.dropLast(3)) : rest
            return (cleaned, (hour, 0))
        }
        if let m = text.firstMatch(of: /(?:\bat )?(\d{1,2})(?::(\d{2}))? ?(am|pm)?$/),
           m.3 != nil || m.2 != nil {  // require am/pm or minutes so "aug 12" isn't a time
            var hour = Int(m.1)!
            let minute = m.2.flatMap { Int($0) } ?? 0
            if m.3 == "pm", hour < 12 { hour += 12 }
            if m.3 == "am", hour == 12 { hour = 0 }
            guard hour < 24, minute < 60 else { return (text, nil) }
            let rest = String(text[..<m.range.lowerBound]).trimmingCharacters(in: .whitespaces)
            return (rest, (hour, minute))
        }
        return (text, nil)
    }

    /// True if `s` is (a prefix of) a snooze date keyword, a tomorrow/today
    /// alias, or a weekday name — i.e. a word a bare trailing hour can attach
    /// to. Deliberately excludes month names so "aug 12" isn't read as a time.
    private static func isDateWord(_ s: String, calendar cal: Calendar) -> Bool {
        let keywords = [
            "today", "tonight", "tomorrow", "later", "later today",
            "next week", "next month", "weekend", "this weekend",
            "end of day", "end of week", "end of month",
        ]
        if keywords.contains(where: { $0.hasPrefix(s) }) { return true }
        let aliases = [
            "tm", "tmr", "tmrw", "tmw", "tmo", "tmoro", "td", "tdy", "tn", "tnt",
            "lt", "l8r", "eod", "eow", "eom", "wknd", "nw", "nm",
        ]
        if aliases.contains(s) { return true }
        // Match the suggestion path: single-letter weekday prefixes ("s 10")
        // must also count as date words for bare trailing hours.
        if cal.weekdaySymbols.contains(where: { $0.lowercased().hasPrefix(s) }) { return true }
        return false
    }

    static func format(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(.dateTime.hour().minute())
        if cal.isDateInToday(date) { return "today \(time)" }
        if cal.isDateInTomorrow(date) { return "tomorrow \(time)" }
        if cal.component(.year, from: date) != cal.component(.year, from: Date()) {
            return date.formatted(.dateTime.month(.abbreviated).day().year()) + " \(time)"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " \(time)"
    }

    /// Undo-toast label for a confirmed snooze. Shared so the hot path never
    /// allocates a `DateFormatter` and the wording stays consistent with the
    /// picker captions.
    static func undoLabel(until date: Date) -> String {
        "Snoozed until \(format(date))"
    }
}
