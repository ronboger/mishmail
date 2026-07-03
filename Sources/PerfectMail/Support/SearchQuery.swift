import Foundation

/// Parsed search query (Cmd-K and the search field). Supports Gmail-style
/// operators alongside free text:
///   from:alice   from:"Alice Smith"   label:work   label:"Deal Flow"   has:attachment
/// Operators are case-insensitive; everything else is full-text search.
struct SearchQuery: Equatable {
    var text = ""
    var from: String?
    var labels: [String] = []
    var hasAttachment = false

    /// True when the query is operators-only (no full-text part).
    var isFilterOnly: Bool {
        text.isEmpty && (from != nil || !labels.isEmpty || hasAttachment)
    }

    static func parse(_ raw: String) -> SearchQuery {
        var q = SearchQuery()
        var freeText: [String] = []
        for token in tokenize(raw) {
            let lower = token.lowercased()
            if lower.hasPrefix("from:") {
                let value = unquote(String(token.dropFirst("from:".count)))
                if !value.isEmpty { q.from = value }
            } else if lower.hasPrefix("label:") {
                let value = unquote(String(token.dropFirst("label:".count)))
                if !value.isEmpty { q.labels.append(value) }
            } else if lower == "has:attachment" {
                q.hasAttachment = true
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
}
