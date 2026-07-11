import Foundation

/// Best-effort local matching of a Gmail filter's structured criteria against
/// a message. Gmail's full search grammar is not reimplemented — free-text
/// `query` / `negatedQuery` tokens are treated as case-insensitive substrings
/// over from/to/cc/subject/snippet/body, with a few common operators
/// (`from:`, `to:`, `subject:`, `has:attachment`) recognized.
///
/// Used to surface "which of your filters match this email" under a message
/// card. Conservative on unknowns: a size criterion with no local size does
/// not match (we never claim a hit we can't evaluate).
enum GmailFilterMatch {

    /// Fields needed to evaluate a filter without a full Gmail search.
    struct MessageFields: Equatable {
        var from: String
        var to: String
        var cc: String
        var subject: String
        var snippet: String
        var bodyText: String
        var hasAttachment: Bool
        /// RFC822 size in bytes when known. Message rows don't store this
        /// today, so callers usually leave it nil.
        var sizeBytes: Int?

        init(from: String, to: String, cc: String = "", subject: String,
             snippet: String = "", bodyText: String = "",
             hasAttachment: Bool, sizeBytes: Int? = nil) {
            self.from = from
            self.to = to
            self.cc = cc
            self.subject = subject
            self.snippet = snippet
            self.bodyText = bodyText
            self.hasAttachment = hasAttachment
            self.sizeBytes = sizeBytes
        }

        init(_ message: Message) {
            self.init(
                from: message.fromHeader,
                to: message.toHeader,
                cc: message.ccHeader,
                subject: message.subject,
                snippet: message.snippet,
                bodyText: message.bodyText,
                hasAttachment: message.hasAttachment)
        }
    }

    /// Filters whose criteria all match `message`. Order is preserved.
    static func matching(_ filters: [GFilter], message: MessageFields) -> [GFilter] {
        filters.filter { matches($0, message: message) }
    }

    /// True when every present criterion on the filter matches `message`.
    /// A filter with no criteria (Gmail "matches everything") returns true.
    static func matches(_ filter: GFilter, message: MessageFields) -> Bool {
        matches(filter.criteria, message: message)
    }

    static func matches(_ criteria: GFilter.Criteria?, message: MessageFields) -> Bool {
        guard let c = criteria else { return true }

        if let from = c.from, !from.isEmpty {
            guard containsToken(message.from, token: from) else { return false }
        }
        if let to = c.to, !to.isEmpty {
            let hay = [message.to, message.cc].joined(separator: " ")
            guard containsToken(hay, token: to) else { return false }
        }
        if let subject = c.subject, !subject.isEmpty {
            guard containsToken(message.subject, token: subject) else { return false }
        }
        if c.hasAttachment == true, !message.hasAttachment { return false }
        if let size = c.size {
            guard let msgSize = message.sizeBytes else { return false }
            if c.sizeComparison == "smaller" {
                if msgSize >= size { return false }
            } else {
                // Gmail default / "larger"
                if msgSize <= size { return false }
            }
        }
        if let q = c.query, !q.isEmpty {
            guard matchesQuery(q, message: message) else { return false }
        }
        if let nq = c.negatedQuery, !nq.isEmpty {
            if matchesQuery(nq, message: message) { return false }
        }
        return true
    }

    // MARK: - Query tokens

    /// Space-separated tokens; double-quoted phrases stay together.
    /// Boolean operators (`OR` / `AND`) are not returned — callers split on
    /// OR first via `splitTopLevelOR`.
    static func tokenize(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in query {
            if ch == "\"" {
                inQuotes.toggle()
                continue
            }
            if ch.isWhitespace, !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Split a Gmail-style query on top-level `OR` (case-insensitive word,
    /// not inside quotes). Gmail requires uppercase `OR`; we accept any case
    /// so user-typed filters still work.
    static func splitTopLevelOR(_ query: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(query)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
                i += 1
                continue
            }
            if !inQuotes, let orLen = orOperatorLength(chars, at: i) {
                let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { parts.append(piece) }
                current = ""
                i += orLen
                continue
            }
            current.append(ch)
            i += 1
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { parts.append(tail) }
        return parts.isEmpty ? [query] : parts
    }

    /// Length of an `OR` operator at `i` including surrounding whitespace
    /// that delimits it as a word; nil if this isn't an OR.
    private static func orOperatorLength(_ chars: [Character], at i: Int) -> Int? {
        // Leading whitespace is optional at start of string; required as a
        // word boundary mid-string (so "from:aORb" is not an OR).
        var j = i
        var leadingWS = 0
        while j < chars.count, chars[j].isWhitespace {
            leadingWS += 1
            j += 1
        }
        guard j + 1 < chars.count else { return nil }
        let c0 = chars[j], c1 = chars[j + 1]
        // Match "or" case-insensitively as a whole word.
        guard String([c0, c1]).lowercased() == "or" else { return nil }
        let after = j + 2
        // Word boundary after OR: end of string or whitespace.
        if after < chars.count, !chars[after].isWhitespace { return nil }
        // Word boundary before OR: start, or we consumed whitespace, or
        // the previous non-space was already flushed (caller only invokes
        // at token starts after whitespace / beginning). Require either
        // start-of-string or at least one leading whitespace when i > 0.
        if i > 0, leadingWS == 0 { return nil }
        // Consume trailing whitespace after OR so the next alternative is clean.
        var end = after
        while end < chars.count, chars[end].isWhitespace { end += 1 }
        // Don't treat a trailing OR with nothing after as an operator split
        // that drops the rest — still split (empty right side filtered later).
        return end - i
    }

    /// Gmail query matching: top-level `OR` alternatives, each AND of tokens.
    /// Unary `-term` / `-from:x` negates a single token. Bare `OR`/`AND`
    /// operator tokens are ignored (never matched as the substring "or").
    static func matchesQuery(_ query: String, message: MessageFields) -> Bool {
        let alternatives = splitTopLevelOR(query)
        return alternatives.contains { matchesQueryAND($0, message: message) }
    }

    private static func matchesQueryAND(_ query: String, message: MessageFields) -> Bool {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return true }
        for token in tokens {
            let lower = token.lowercased()
            // Boolean operators left over after OR-splitting — never treat as
            // free-text (the old bug: "or" matched almost every body).
            if lower == "or" || lower == "and" { continue }
            if token.hasPrefix("-"), token.count > 1 {
                let positive = String(token.dropFirst())
                if matchesToken(positive, message: message) { return false }
                continue
            }
            if !matchesToken(token, message: message) { return false }
        }
        return true
    }

    private static func matchesToken(_ token: String, message: MessageFields) -> Bool {
        let lower = token.lowercased()
        if lower == "has:attachment" { return message.hasAttachment }
        if lower.hasPrefix("from:") {
            return containsToken(message.from, token: String(token.dropFirst(5)))
        }
        if lower.hasPrefix("to:") {
            let hay = [message.to, message.cc].joined(separator: " ")
            return containsToken(hay, token: String(token.dropFirst(3)))
        }
        if lower.hasPrefix("subject:") {
            return containsToken(message.subject, token: String(token.dropFirst(8)))
        }
        // Free text: any of the usual header/body surfaces.
        let hay = [
            message.from, message.to, message.cc,
            message.subject, message.snippet, message.bodyText
        ].joined(separator: "\n")
        return containsToken(hay, token: token)
    }

    /// Case-insensitive substring. Empty token is a no-op match.
    static func containsToken(_ haystack: String, token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return true }
        return haystack.range(of: t, options: .caseInsensitive) != nil
    }
}
