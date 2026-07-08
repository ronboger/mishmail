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

        let (datePart, time) = splitTime(from: text)
        var results: [Suggestion] = []

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

        // Bare time ("3pm", "at 17:30") → today, or tomorrow if already past.
        if datePart.isEmpty, time != nil {
            let today = at(now)
            add("Today", today)
            if let today, today <= now {
                add("Tomorrow", at(cal.date(byAdding: .day, value: 1, to: now)!))
            }
        }

        // Keywords, prefix-matched.
        let keywords: [(String, () -> Date?)] = [
            ("today", { at(now) }),
            ("tonight", { at(now, 20) }),
            ("tomorrow", { at(cal.date(byAdding: .day, value: 1, to: now)!) }),
            ("next week", { at(nextWeekday(2)) }),          // Monday
            ("next month", {
                let comps = cal.dateComponents([.year, .month], from: cal.date(byAdding: .month, value: 1, to: now)!)
                return at(cal.date(from: comps)!)
            }),
            ("weekend", { at(nextWeekday(7)) }),            // Saturday
            ("this weekend", { at(nextWeekday(7)) }),
        ]
        for (word, make) in keywords where word.hasPrefix(datePart) {
            add(word.capitalized, make())
        }

        // Weekday names, prefix-matched ("fri" → Friday). Min 2 chars so a
        // single "t" doesn't drown the list in weekdays.
        if datePart.count >= 2 {
            let symbols = cal.weekdaySymbols  // Sunday-first
            for (i, name) in symbols.enumerated() where name.lowercased().hasPrefix(datePart) {
                add(name, at(nextWeekday(i + 1)))
            }
        }

        // "in N days/hours/weeks/months"
        if let m = text.wholeMatch(of: /in (\d+) ?(hour|day|week|month)s?/) {
            let n = Int(m.1)!
            let unit: Calendar.Component = ["hour": .hour, "day": .day, "week": .weekOfYear, "month": .month][String(m.2)]!
            let target = cal.date(byAdding: unit, value: n, to: now)!
            add("In \(n) \(m.2)\(n == 1 ? "" : "s")", unit == .hour ? target : at(target))
        }

        // "aug 12" / "12 aug" / "8/12"
        let months = cal.monthSymbols.map { $0.lowercased() }
        func monthDay(month: Int, day: Int) -> Date? {
            var comps = DateComponents(year: cal.component(.year, from: now), month: month, day: day)
            guard let d = cal.date(from: comps) else { return nil }
            if let dated = at(d), dated > now { return dated }
            comps.year! += 1
            return cal.date(from: comps).flatMap { at($0) }
        }
        if let m = datePart.wholeMatch(of: /([a-z]{3,}) (\d{1,2})/),
           let month = months.firstIndex(where: { $0.hasPrefix(String(m.1)) }) {
            add("\(cal.monthSymbols[month]) \(m.2)", monthDay(month: month + 1, day: Int(m.2)!))
        } else if let m = datePart.wholeMatch(of: /(\d{1,2}) ([a-z]{3,})/),
                  let month = months.firstIndex(where: { $0.hasPrefix(String(m.2)) }) {
            add("\(cal.monthSymbols[month]) \(m.1)", monthDay(month: month + 1, day: Int(m.1)!))
        } else if let m = datePart.wholeMatch(of: /(\d{1,2})\/(\d{1,2})/) {
            add("\(cal.monthSymbols[Int(m.1)! - 1]) \(m.2)", monthDay(month: Int(m.1)!, day: Int(m.2)!))
        }

        return Array(results.prefix(5))
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

    static func format(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(.dateTime.hour().minute())
        if cal.isDateInToday(date) { return "today \(time)" }
        if cal.isDateInTomorrow(date) { return "tomorrow \(time)" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " \(time)"
    }
}
