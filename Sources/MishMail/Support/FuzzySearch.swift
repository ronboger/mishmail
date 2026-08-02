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
        let needle = term.lowercased()
        guard needle.count >= 3 else { return [] }
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
            guard cand.count >= 3 else { continue }
            guard let dist = damerauLevenshtein(needle, cand, max: maxDist) else { continue }
            ranked.append(Ranked(
                term: cand,
                dist: dist,
                prefix: sharedPrefixLength(needle, cand),
                len: cand.count
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

        for token in tokens {
            if token.count < 3 {
                groups.append([token])
                continue
            }
            let maxDist = allowedDistance(forLength: token.count)
            let minLen = max(1, token.count - maxDist)
            let maxLen = token.count + maxDist
            let vocab = try String.fetchAll(db, sql: """
                SELECT term FROM message_fts_vocab
                WHERE length(term) BETWEEN ? AND ?
                ORDER BY doc DESC
                LIMIT 5000
                """, arguments: [minLen, maxLen])

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

    static func sharedPrefixLength(_ a: String, _ b: String) -> Int {
        let ac = Array(a)
        let bc = Array(b)
        let n = min(ac.count, bc.count)
        var i = 0
        while i < n, ac[i] == bc[i] { i += 1 }
        return i
    }

    /// Bounded Damerau–Levenshtein (includes adjacent transposition).
    /// Returns `nil` when the distance would exceed `max` (early-exit on
    /// row minimum, and when `|n-m| > max`).
    static func damerauLevenshtein(_ a: String, _ b: String, max maxDist: Int) -> Int? {
        if maxDist < 0 { return nil }
        let aChars = Array(a)
        let bChars = Array(b)
        let n = aChars.count
        let m = bChars.count
        if abs(n - m) > maxDist { return nil }
        if n == 0 { return m <= maxDist ? m : nil }
        if m == 0 { return n <= maxDist ? n : nil }

        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }

        for i in 1...n {
            var rowMin = Int.max
            for j in 1...m {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                var v = min(
                    d[i - 1][j] + 1,          // deletion
                    d[i][j - 1] + 1,          // insertion
                    d[i - 1][j - 1] + cost   // substitution
                )
                // Adjacent transposition
                if i > 1, j > 1,
                   aChars[i - 1] == bChars[j - 2],
                   aChars[i - 2] == bChars[j - 1] {
                    v = min(v, d[i - 2][j - 2] + 1)
                }
                d[i][j] = v
                if v < rowMin { rowMin = v }
            }
            if rowMin > maxDist { return nil }
        }
        let dist = d[n][m]
        return dist <= maxDist ? dist : nil
    }
}
