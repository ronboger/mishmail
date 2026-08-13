import Foundation

extension Date {
    /// "Sep 25 at 3:49 PM" for dates in the current year,
    /// "Sep 25, 2025 at 3:49 PM" for older (or future-year) dates.
    var messageHeaderFormat: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        if !Calendar.current.isDate(self, equalTo: .now, toGranularity: .year) {
            style = style.year()
        }
        return style.hour().minute()
    }

    /// Compact list style: time today, "Sep 25" this year, "Sep 25, 2025" otherwise.
    var threadListFormat: Date.FormatStyle {
        if Calendar.current.isDateInToday(self) {
            return .dateTime.hour().minute()
        }
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        if !Calendar.current.isDate(self, equalTo: .now, toGranularity: .year) {
            style = style.year()
        }
        return style
    }
}
