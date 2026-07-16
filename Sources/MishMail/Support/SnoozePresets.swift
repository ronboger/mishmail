import Foundation

/// Time-of-day-aware snooze presets for the picker and context menu.
///
/// Late night (after midnight, before morning hour) is the awkward case:
/// "This evening / today 6pm" is still on the calendar day but ~18h away,
/// while the natural "snooze until I wake up" target is *this* morning —
/// not "Tomorrow morning" (the next calendar day). Anchors that have
/// already passed are dropped so the first option is always the soonest
/// useful wake time.
enum SnoozePresets {
    struct Preset: Equatable {
        let title: String
        let date: Date
    }

    /// Morning / afternoon / evening anchors on the current calendar day.
    /// Tuned to match the old hard-coded 8am / 6pm times, plus a midday
    /// option so late-morning snoozes don't jump straight to evening.
    static let morningHour = 8
    static let afternoonHour = 13
    static let eveningHour = 18

    /// Presets ordered soonest-first. Pure date math so unit tests can pin
    /// `now` without UI.
    static func presets(now: Date = Date(), calendar cal: Calendar = .current) -> [Preset] {
        var list: [Preset] = []

        func at(hour: Int, on day: Date) -> Date {
            cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        }
        func add(_ title: String, _ date: Date) {
            guard date > now else { return }
            // Same instant, different semantics (Fri→Sat: "Tomorrow morning"
            // and "This weekend"; Sun→Mon: "Tomorrow morning" and "Next week").
            // Keep one row and merge titles so neither label is silently dropped.
            if let i = list.firstIndex(where: { $0.date == date }) {
                let existing = list[i].title
                if !existing.contains(title) {
                    list[i] = Preset(title: "\(existing) · \(title)", date: date)
                }
                return
            }
            list.append(Preset(title: title, date: date))
        }

        // Same-day dayparts still ahead of `now`.
        add("This morning", at(hour: morningHour, on: now))
        add("This afternoon", at(hour: afternoonHour, on: now))
        add("This evening", at(hour: eveningHour, on: now))

        // Next calendar morning — the classic "I'll deal with this tomorrow"
        // target. Distinct from "This morning" once morning has passed, and
        // still useful at 1am when you want *tomorrow's* morning, not today's.
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now)!
        add("Tomorrow morning", at(hour: morningHour, on: tomorrow))

        // Next Saturday / next Monday at morning hour. `nextDate(after:)`
        // never returns today, so Saturday night still lands on next weekend.
        if let saturday = cal.nextDate(after: now,
                                       matching: DateComponents(weekday: 7),
                                       matchingPolicy: .nextTime) {
            add("This weekend", at(hour: morningHour, on: saturday))
        }
        if let monday = cal.nextDate(after: now,
                                     matching: DateComponents(weekday: 2),
                                     matchingPolicy: .nextTime) {
            add("Next week", at(hour: morningHour, on: monday))
        }

        return list
    }
}
