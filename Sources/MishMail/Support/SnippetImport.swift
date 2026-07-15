import Foundation

/// JSON snippet import (Settings → Snippets → Import): an array of
/// `{"name": "...", "body": "...", "movesToBcc": true, "accountIds": ["…"]}`
/// objects — an easy hand-conversion target for a Notion Mail snippet export.
enum SnippetImport {
    struct Item: Codable, Equatable {
        var name: String
        var body: String
        var movesToBcc: Bool?
        /// Optional account emails that may use this snippet. Omitted/empty =
        /// available on every account.
        var accountIds: [String]? = nil
    }

    static func decode(_ data: Data) throws -> [Item] {
        try JSONDecoder().decode([Item].self, from: data)
    }

    /// Which items to actually insert: drops blanks and anything whose name
    /// (case-insensitively) already exists, so re-importing is harmless.
    static func plan(_ items: [Item], existingNames: [String]) -> [Item] {
        var taken = Set(existingNames.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        })
        return items.filter { item in
            let name = item.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  taken.insert(name.lowercased()).inserted else { return false }
            return true
        }
    }
}
