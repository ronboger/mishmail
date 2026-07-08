import Foundation

/// Shared label-search predicate (the "l" picker + the Labels filter chip):
/// every whitespace token of the query must appear in the name, compared
/// locale-aware and case/diacritic-insensitively.
enum LabelSearch {
    static func matches(_ name: String, query: String) -> Bool {
        query.split(separator: " ").allSatisfy { name.localizedStandardContains($0) }
    }
}
