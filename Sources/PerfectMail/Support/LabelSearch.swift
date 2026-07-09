import Foundation

/// Shared label-search predicate (the "l" picker + the Labels filter chip):
/// every whitespace token of the query must appear in the name, compared
/// locale-aware and case/diacritic-insensitively.
enum LabelSearch {
    static func matches(_ name: String, query: String) -> Bool {
        query.split(separator: " ").allSatisfy { name.localizedStandardContains($0) }
    }

    /// Gmail-style match highlighting: bolds each query token's first
    /// occurrence in the name (case/diacritic-insensitive), same comparison
    /// as `matches`.
    static func highlighted(_ name: String, query: String) -> AttributedString {
        var attributed = AttributedString(name)
        for token in query.split(separator: " ") {
            guard let found = name.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]),
                  let range = Range(found, in: attributed) else { continue }
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
        }
        return attributed
    }
}
