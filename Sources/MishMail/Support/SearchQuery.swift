import Foundation

/// Parsed search query (Cmd-K and the search field). Supports Gmail-style
/// operators alongside free text:
///   from:alice  from:"Alice Smith"  to:bob  subject:invoice  label:work
///   label:"Deal Flow"  has:attachment  is:unread  is:starred
///   after:2026/07/01  before:2026-07-31
/// Operators are case-insensitive; everything else is full-text search.
struct SearchQuery: Equatable {
    var text = ""
    var from: String?
    var to: String?
    var subject: String?
    var labels: [String] = []
    var hasAttachment = false
    /// nil = don't care, true = unread only, false = read only.
    var unread: Bool?
    var starred = false
    /// Inclusive lower bound (messages on/after this day, start-of-day).
    var after: Date?
    /// Exclusive upper bound (messages strictly before this day, start-of-day).
    var before: Date?

    /// True when the query is operators-only (no full-text part).
    var isFilterOnly: Bool {
        text.isEmpty && (from != nil || to != nil || subject != nil
            || !labels.isEmpty || hasAttachment || unread != nil || starred
            || after != nil || before != nil)
    }

    static func parse(_ raw: String) -> SearchQuery {
        var q = SearchQuery()
        var freeText: [String] = []
        for token in tokenize(raw) {
            let lower = token.lowercased()
            if lower.hasPrefix("from:") {
                let value = unquote(String(token.dropFirst("from:".count)))
                if !value.isEmpty { q.from = value }
            } else if lower.hasPrefix("to:") {
                let value = unquote(String(token.dropFirst("to:".count)))
                if !value.isEmpty { q.to = value }
            } else if lower.hasPrefix("subject:") {
                let value = unquote(String(token.dropFirst("subject:".count)))
                if !value.isEmpty { q.subject = value }
            } else if lower.hasPrefix("label:") {
                let value = unquote(String(token.dropFirst("label:".count)))
                if !value.isEmpty { q.labels.append(value) }
            } else if lower == "has:attachment" {
                q.hasAttachment = true
            } else if lower == "is:unread" {
                q.unread = true
            } else if lower == "is:read" {
                q.unread = false
            } else if lower == "is:starred" {
                q.starred = true
            } else if lower.hasPrefix("after:"), let d = parseDate(String(token.dropFirst("after:".count))) {
                q.after = d
            } else if lower.hasPrefix("before:"), let d = parseDate(String(token.dropFirst("before:".count))) {
                q.before = d
            } else {
                freeText.append(token)
            }
        }
        q.text = freeText.joined(separator: " ")
        return q
    }

    /// Split on whitespace, keeping quoted spans (`from:"John Doe"`) together.
    static func tokenize(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in raw {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if ch.isWhitespace && !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func unquote(_ s: String) -> String {
        var v = s
        if v.hasPrefix("\"") { v.removeFirst() }
        if v.hasSuffix("\"") { v.removeLast() }
        return v.trimmingCharacters(in: .whitespaces)
    }

    /// Parses `YYYY/MM/DD` or `YYYY-MM-DD` (Gmail-style) into that day's
    /// start-of-day in the local calendar. Returns nil on anything else, so a
    /// bad date leaves the token as free text.
    static func parseDate(_ s: String) -> Date? {
        let parts = s.split(whereSeparator: { $0 == "/" || $0 == "-" })
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d), y >= 1970 else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        guard let date = Calendar.current.date(from: comps) else { return nil }
        // Calendar.date(from:) rolls impossible days over (Feb 30 → Mar 2)
        // rather than failing, so reject anything that didn't round-trip.
        let check = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard check.year == y, check.month == m, check.day == d else { return nil }
        return Calendar.current.startOfDay(for: date)
    }
}
