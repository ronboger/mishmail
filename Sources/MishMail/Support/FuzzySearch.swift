import Foundation
import GRDB

/// Typo-tolerant fallback for local FTS search when the strict prefix MATCH
/// returns no hits. Hostless-testable (mirrors `ThreadTypeahead`).
///
/// Strict results are never diluted: callers only invoke this after an empty
/// strict `message_fts` query. Ranking uses bounded Damerau–Levenshtein against
/// the FTS vocabulary (`message_fts_vocab`, migration v31).
enum FuzzySearch {

    /// Ranked vocabulary near-matches for a single query token.
    ///
    /// - Skips terms shorter than 3 characters (too noisy).
    /// - Allowed edit distance: 1 for length 3–5, 2 for length ≥ 6
    ///   (insert/delete/substitute + adjacent transposition).
    /// - Order: smaller distance, then longer shared prefix, then shorter
    ///   candidate, then lexicographic. At most `limit` results.
    static func candidates(for term: String, in vocab: [String], limit: Int = 3) -> [String] {
        let needle = Array(term.lowercased())
        guard limit > 0, needle.count >= 3 else { return [] }
        let maxDist = allowedDistance(forLength: needle.count)

        struct Ranked {
            let term: String
            let dist: Int
            let prefix: Int
            let len: Int
        }

        var ranked: [Ranked] = []
        ranked.reserveCapacity(min(vocab.count, 64))
        for raw in vocab {
            let cand = raw.lowercased()
            let characters = Array(cand)
            guard characters.count >= 3,
                  let dist = damerauLevenshtein(needle, characters, max: maxDist)
            else { continue }
            ranked.append(Ranked(
                term: cand,
                dist: dist,
                prefix: zip(needle, characters).prefix(while: { $0 == $1 }).count,
                len: characters.count
            ))
        }

        ranked.sort { a, b in
            if a.dist != b.dist { return a.dist < b.dist }
            if a.prefix != b.prefix { return a.prefix > b.prefix }
            if a.len != b.len { return a.len < b.len }
            return a.term < b.term
        }

        var seen = Set<String>()
        var out: [String] = []
        out.reserveCapacity(limit)
        for r in ranked {
            guard seen.insert(r.term).inserted else { continue }
            out.append(r.term)
            if out.count >= limit { break }
        }
        return out
    }

    /// Build an expanded FTS5 pattern for `text`, or `nil` when no token gained
    /// an alternative (no point re-querying) / pattern validation fails.
    ///
    /// Tokenization is a simple unicode61 approximation: lowercase, split on
    /// non-alphanumerics, drop empties. Real FTS tokenization may differ for
    /// apostrophes and punctuation; that is acceptable for fallback ranking.
    ///
    /// Pattern shape: AND of OR-groups, each term double-quoted (embedded `"`
    /// doubled). Prefix `*` is appended to every candidate in the **last**
    /// token's group only (type-ahead parity with `matchingAllPrefixesIn`).
    static func expandedPattern(db: Database, text: String) throws -> FTS5Pattern? {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return nil }

        var anyExpanded = false
        var groups: [[String]] = []
        groups.reserveCapacity(tokens.count)
        // Equal-length tokens use the exact same bounded vocabulary query.
        // Reuse it within this read only, so later searches see fresh mail.
        var vocabularyByLength: [Int: [String]] = [:]

        for token in tokens {
            let length = token.count
            if length < 3 {
                groups.append([token])
                continue
            }
            let vocab: [String]
            if let cached = vocabularyByLength[length] {
                vocab = cached
            } else {
                let maxDist = allowedDistance(forLength: length)
                let minLen = max(1, length - maxDist)
                let maxLen = length + maxDist
                vocab = try String.fetchAll(db, sql: """
                    SELECT term FROM message_fts_vocab
                    WHERE length(term) BETWEEN ? AND ?
                    ORDER BY doc DESC
                    LIMIT 5000
                    """, arguments: [minLen, maxLen])
                vocabularyByLength[length] = vocab
            }

            let alts = candidates(for: token, in: vocab, limit: 3)
            var group: [String] = [token]
            for alt in alts where alt != token {
                group.append(alt)
            }
            if group.count > 1 { anyExpanded = true }
            groups.append(group)
        }

        guard anyExpanded else { return nil }

        let raw = buildRawPattern(groups: groups)
        // Validate via GRDB/SQLite; never throw out of the search path.
        return try? db.makeFTS5Pattern(rawPattern: raw, forTable: "message_fts")
    }

    // MARK: - Internals

    static func allowedDistance(forLength length: Int) -> Int {
        length <= 5 ? 1 : 2
    }

    /// Lowercase + split on non-alphanumerics (unicode61 approximation).
    static func tokenize(_ text: String) -> [String] {
        let lower = text.lowercased()
        return lower.split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func buildRawPattern(groups: [[String]]) -> String {
        let last = groups.count - 1
        return groups.enumerated().map { idx, group in
            let isLast = idx == last
            let terms = group.map { quoteFTS5Term($0, prefix: isLast) }
            if terms.count == 1 { return terms[0] }
            return "(\(terms.joined(separator: " OR ")))"
        }.joined(separator: " AND ")
    }

    /// Double-quote an FTS5 term; double embedded quotes. Optional prefix `*`.
    static func quoteFTS5Term(_ term: String, prefix: Bool) -> String {
        let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
        let quoted = "\"\(escaped)\""
        return prefix ? "\(quoted)*" : quoted
    }

    /// A match within the limit never leaves the diagonal band. Retain the
    /// preceding two rows so an adjacent transposition still costs one edit.
    private static func damerauLevenshtein(_ a: [Character], _ b: [Character],
                                           max limit: Int) -> Int? {
        let n = a.count, m = b.count
        guard abs(n - m) <= limit else { return nil }
        let outside = limit + 1
        var previous = Array(0...m)
        var twoBack = Array(repeating: outside, count: m + 1)
        var current = Array(repeating: outside, count: m + 1)

        for i in 1...n {
            let first = max(1, i - limit)
            let last = min(m, i + limit)
            current[first - 1] = first == 1 ? i : outside
            if last < m { current[last + 1] = outside }
            var rowMin = outside
            for j in first...last {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                var value = min(previous[j] + 1, current[j - 1] + 1, substitution)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, twoBack[j - 2] + 1)
                }
                current[j] = value
                rowMin = min(rowMin, value)
            }
            guard rowMin <= limit else { return nil }
            swap(&twoBack, &previous)
            swap(&previous, &current)
        }
        return previous[m] <= limit ? previous[m] : nil
    }
}
