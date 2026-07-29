import Foundation

/// Pure row list for the snooze / schedule-send date picker.
///
/// Extracted so the press-`b` empty-query path is unit-testable without
/// mounting SwiftUI. Presets map to formatted captions; a non-empty query
/// delegates to `SnoozeDateParser`.
enum DatePickRows {
    struct Row: Equatable {
        let title: String
        let detail: String
        /// `.some(date)` picks a date; `.some(nil)` is the clear/unsnooze row.
        let action: Date??
    }

    static func rows(
        query: String,
        presets: [(title: String, date: Date)],
        clearOption: (title: String, detail: String)?,
        minDate: Date? = nil,
        now: Date = Date()
    ) -> [Row] {
        var list: [Row] = []
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            list = presets.map {
                Row(title: $0.title, detail: SnoozeDateParser.format($0.date), action: $0.date)
            }
        } else {
            list = SnoozeDateParser.suggestions(for: query, now: now)
                .filter { s in minDate.map { s.date > $0 } ?? true }
                .map { s in
                    let parts = s.label.components(separatedBy: "  ·  ")
                    return Row(title: parts.first ?? s.label,
                               detail: parts.count > 1 ? parts[1] : "",
                               action: s.date)
                }
        }
        if let clearOption {
            list.append(Row(title: clearOption.title, detail: clearOption.detail,
                            action: .some(nil)))
        }
        return list
    }
}
