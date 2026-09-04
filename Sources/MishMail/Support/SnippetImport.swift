import Foundation

/// JSON / CSV snippet import (Settings → Snippets and Moving from Notion Mail).
///
/// Accepts MishMail's own array (`[{"name","body",…}]`) and the shapes a
/// Notion Mail snippet export commonly lands in: a `{ "snippets": […] }`
/// wrapper, alternate keys (`shortcut`/`content`), and CSV with a header row.
enum SnippetImport {
    struct Item: Codable, Equatable {
        var name: String
        var body: String
        var movesToBcc: Bool?
        /// Optional account emails that may use this snippet. Omitted/empty =
        /// available on every account.
        var accountIds: [String]? = nil
    }

    enum ImportError: LocalizedError {
        case unrecognized

        var errorDescription: String? {
            "Could not read snippets. Use a JSON array or CSV with name and body columns."
        }
    }

    static func decode(_ data: Data) throws -> [Item] {
        let trimmed = stripBOM(data)
        if let items = decodeJSON(trimmed) { return items }
        if let items = decodeCSV(trimmed) { return items }
        throw ImportError.unrecognized
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

    /// Map Notion Mail `{{First Name}}` / `{{Your Name}}` tokens onto the
    /// placeholders MishMail expands. Only known variable names rewrite.
    /// Code braces and custom prompts stay verbatim.
    static func rewriteNotionVariables(_ body: String) -> String {
        guard let regex = placeholderRegex else { return body }
        let ns = body as NSString
        var result = body
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            let inner = ns.substring(with: match.range(at: 1))
            guard let token = canonicalVariable(inner) else { continue }
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: "{\(token)}")
        }
        return result
    }

    // MARK: - JSON

    private static func decodeJSON(_ data: Data) -> [Item]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let arr = obj as? [Any], arr.isEmpty { return [] }
        let rows = snippetRows(from: obj)
        if rows.isEmpty { return nil }
        let items = rows.compactMap(item(from:))
        return items.isEmpty ? nil : items
    }

    private static func snippetRows(from obj: Any) -> [[String: Any]] {
        if let arr = obj as? [Any] {
            return arr.compactMap { $0 as? [String: Any] }
        }
        guard let dict = obj as? [String: Any] else { return [] }
        for key in ["snippets", "items", "data", "records", "templates"] {
            if let arr = dict[key] as? [Any] {
                return arr.compactMap { $0 as? [String: Any] }
            }
        }
        if hasSnippetKeys(dict) { return [dict] }
        return []
    }

    private static func hasSnippetKeys(_ dict: [String: Any]) -> Bool {
        value(dict, keys: nameKeys) != nil || value(dict, keys: bodyKeys) != nil
    }

    private static func item(from dict: [String: Any]) -> Item? {
        guard let name = string(dict, keys: nameKeys),
              let body = string(dict, keys: bodyKeys) else { return nil }
        return Item(
            name: name,
            body: rewriteNotionVariables(body),
            movesToBcc: bool(dict, keys: ["movesToBcc", "moveToBcc", "moves_to_bcc", "bcc"]),
            accountIds: stringArray(dict, keys: ["accountIds", "account_ids", "accounts"]))
    }

    // MARK: - CSV

    private static func decodeCSV(_ data: Data) -> [Item]? {
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16) else { return nil }
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.hasPrefix("{"), !raw.hasPrefix("[") else { return nil }
        let delimiter = raw.contains("\t") && raw.split(separator: "\t").count
            > raw.split(separator: ",").count ? "\t" : ","
        let records = csvRecords(raw, delimiter: Character(delimiter))
        guard records.count >= 2, let header = records.first else { return nil }
        let cols = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let nameIdx = columnIndex(cols, candidates: nameKeys)
            ?? (cols.count >= 2 ? 0 : nil)
        let bodyIdx = columnIndex(cols, candidates: bodyKeys)
            ?? (cols.count >= 2 ? 1 : nil)
        guard let nameIdx, let bodyIdx, nameIdx != bodyIdx else { return nil }
        let bccIdx = columnIndex(cols, candidates: ["movestobcc", "movetobcc", "bcc"])
        var items: [Item] = []
        for row in records.dropFirst() {
            guard nameIdx < row.count, bodyIdx < row.count else { continue }
            let name = row[nameIdx].trimmingCharacters(in: .whitespaces)
            let body = row[bodyIdx]
            guard !name.isEmpty,
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var moves: Bool?
            if let bccIdx, bccIdx < row.count {
                moves = parseBool(row[bccIdx])
            }
            items.append(Item(name: name, body: rewriteNotionVariables(body),
                              movesToBcc: moves, accountIds: nil))
        }
        return items.isEmpty ? nil : items
    }

    // MARK: - Placeholders

    private static let placeholderRegex = try? NSRegularExpression(
        pattern: #"\{{1,2}\s*([A-Za-z][A-Za-z0-9 _-]*?)\s*\}{1,2}"#)

    private static let variableAliases: [String: String] = [
        "first_name": "first_name", "firstname": "first_name", "first": "first_name",
        "last_name": "last_name", "lastname": "last_name", "last": "last_name",
        "name": "name", "full_name": "name", "fullname": "name",
        "recipient": "name", "recipient_name": "name",
        "email": "email", "recipient_email": "email",
        "date": "date", "today": "date",
        "my_name": "my_name", "myname": "my_name",
        "your_name": "my_name", "yourname": "my_name",
        "sender": "my_name", "sender_name": "my_name",
        "my_first_name": "my_first_name", "myfirstname": "my_first_name",
        "your_first_name": "my_first_name", "yourfirstname": "my_first_name",
        "bcc_first_name": "bcc_first_name", "bccfirstname": "bcc_first_name",
        "bcc_name": "bcc_name", "bccname": "bcc_name",
        "bcc_email": "bcc_email", "bccemail": "bcc_email",
        "introducer": "bcc_name",
    ]

    private static func canonicalVariable(_ raw: String) -> String? {
        let key = raw.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "_")
        return variableAliases[key]
    }

    // MARK: - Dict helpers

    private static let nameKeys = [
        "name", "shortcut", "title", "slug", "command", "trigger",
    ]
    private static let bodyKeys = [
        "body", "content", "text", "snippet", "html", "value",
    ]

    private static func value(_ dict: [String: Any], keys: [String]) -> Any? {
        let mapped = Dictionary(uniqueKeysWithValues: dict.map {
            ($0.key.lowercased(), $0.value)
        })
        for key in keys {
            if let v = mapped[key.lowercased()] { return v }
        }
        return nil
    }

    private static func string(_ dict: [String: Any], keys: [String]) -> String? {
        guard let v = value(dict, keys: keys) else { return nil }
        if let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : s
        }
        return nil
    }

    private static func bool(_ dict: [String: Any], keys: [String]) -> Bool? {
        guard let v = value(dict, keys: keys) else { return nil }
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return parseBool(s) }
        return nil
    }

    private static func parseBool(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    private static func stringArray(_ dict: [String: Any], keys: [String]) -> [String]? {
        guard let v = value(dict, keys: keys) else { return nil }
        if let arr = v as? [String] { return arr }
        if let arr = v as? [Any] {
            let strings = arr.compactMap { $0 as? String }
            return strings.isEmpty ? nil : strings
        }
        if let s = v as? String {
            let parts = s.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts
        }
        return nil
    }

    private static func columnIndex(_ cols: [String], candidates: [String]) -> Int? {
        let wanted = Set(candidates.map { $0.lowercased() })
        return cols.firstIndex { wanted.contains($0.replacingOccurrences(of: "_", with: ""))
            || wanted.contains($0) }
    }

    private static func stripBOM(_ data: Data) -> Data {
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            return data.dropFirst(3)
        }
        return data
    }

    /// RFC 4180-ish records. Newlines inside quotes stay in the field.
    private static func csvRecords(_ text: String, delimiter: Character) -> [[String]] {
        var records: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == delimiter {
                row.append(field)
                field = ""
            } else if c == "\n" || c == "\r" {
                if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                row.append(field)
                field = ""
                if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    records.append(row)
                }
                row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        row.append(field)
        if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            records.append(row)
        }
        return records
    }
}
