import Foundation

/// Pure ranking/filtering for the compose `/` picker and snippet panel so
/// the best name match surfaces first and account-scoped snippets stay out
/// of the wrong mailbox's picker.
enum SnippetMatch {
    /// Snippets available for `accountId`, ranked for `query`.
    /// Empty query → all available snippets (name-sorted by caller/store).
    /// Non-empty → name contains query, ordered exact → prefix → contains.
    static func ranked(_ snippets: [Snippet],
                       query: String,
                       accountId: String) -> [Snippet] {
        let available = snippets.filter { $0.isAvailable(for: accountId) }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return available }
        return available
            .filter { $0.name.localizedCaseInsensitiveContains(q) }
            .sorted { a, b in
                let sa = score(name: a.name, query: q)
                let sb = score(name: b.name, query: q)
                if sa != sb { return sa > sb }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    /// Higher is better: exact (300) > prefix (200) > substring (100).
    static func score(name: String, query: String) -> Int {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return 0 }
        if n.compare(q, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return 300
        }
        if n.localizedCaseInsensitiveHasPrefix(q) { return 200 }
        if n.localizedCaseInsensitiveContains(q) { return 100 }
        return 0
    }
}

private extension String {
    func localizedCaseInsensitiveHasPrefix(_ prefix: String) -> Bool {
        guard let range = range(of: prefix, options: [.caseInsensitive, .diacriticInsensitive, .anchored])
        else { return false }
        return range.lowerBound == startIndex
    }
}
