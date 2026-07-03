import Foundation

/// Preset send times for schedule-send (Notion Mail-style), plus display
/// helpers. Pure date math so it's unit-testable.
enum SendSchedule: CaseIterable {
    case tomorrowMorning    // tomorrow 8:00 AM
    case tomorrowAfternoon  // tomorrow 1:00 PM
    case mondayMorning      // next Monday 8:00 AM (a week out if today is Monday)

    var title: String {
        switch self {
        case .tomorrowMorning: return "Tomorrow morning"
        case .tomorrowAfternoon: return "Tomorrow afternoon"
        case .mondayMorning: return "Monday morning"
        }
    }

    func date(after now: Date = Date(), calendar cal: Calendar = .current) -> Date {
        switch self {
        case .tomorrowMorning:
            let day = cal.date(byAdding: .day, value: 1, to: now)!
            return cal.date(bySettingHour: 8, minute: 0, second: 0, of: day)!
        case .tomorrowAfternoon:
            let day = cal.date(byAdding: .day, value: 1, to: now)!
            return cal.date(bySettingHour: 13, minute: 0, second: 0, of: day)!
        case .mondayMorning:
            var day = cal.date(byAdding: .day, value: 1, to: now)!
            while cal.component(.weekday, from: day) != 2 {  // 2 = Monday
                day = cal.date(byAdding: .day, value: 1, to: day)!
            }
            return cal.date(bySettingHour: 8, minute: 0, second: 0, of: day)!
        }
    }

    /// "today at 5:30 PM", "tomorrow at 8:00 AM", "Monday, Jul 6 at 8:00 AM".
    static func describe(_ date: Date, relativeTo now: Date = Date(),
                         calendar cal: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
           cal.isDate(date, inSameDayAs: tomorrow) { return "tomorrow at \(time)" }
        let day = date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        return "\(day) at \(time)"
    }
}
