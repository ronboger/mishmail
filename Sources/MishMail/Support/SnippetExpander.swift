import Foundation

/// Expands `{{variable}}` and `{variable}` placeholders in a snippet body.
/// Pure and case-insensitive on the variable name; unknown placeholders are
/// left as-is. Recipient variables (name, first_name, last_name, email) fill
/// from the first To recipient; my_* from the sending account; bcc_* from the
/// person a move-to-bcc snippet moved out of To (the introducer).
enum SnippetExpander {
    struct Context {
        var recipientName: String = ""
        var recipientEmail: String = ""
        var date: String = ""
        var myName: String = ""
        var bccName: String = ""
        var bccEmail: String = ""
    }

    /// Every supported placeholder, with a blurb for editor UI. Order is the
    /// order autocomplete offers them.
    static let variables: [(token: String, blurb: String)] = [
        ("{first_name}", "recipient's first name"),
        ("{name}", "recipient's full name"),
        ("{last_name}", "recipient's last name"),
        ("{email}", "recipient's address"),
        ("{date}", "today's date"),
        ("{my_first_name}", "your first name"),
        ("{my_name}", "your full name"),
        ("{bcc_first_name}", "introducer moved to Bcc"),
        ("{bcc_name}", "introducer's full name"),
        ("{bcc_email}", "introducer's address"),
    ]

    static let knownKeys: Set<String> = Set(variables.map {
        $0.token.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
    })

    /// A placeholder found in a template: its location, bare name, and
    /// whether it's one the expander fills (unknown ones stay literal —
    /// fill-in-yourself prompts like `{key_point_1}`).
    struct Placeholder {
        var range: NSRange
        var name: String
        var known: Bool
    }

    private static let placeholderRegex = try! NSRegularExpression(
        pattern: #"\{{1,2}\s*([A-Za-z0-9_]+)\s*\}{1,2}"#)

    /// All `{name}` / `{{name}}` placeholders in a template, for highlighting.
    static func placeholders(in template: String) -> [Placeholder] {
        let ns = template as NSString
        return placeholderRegex
            .matches(in: template, range: NSRange(location: 0, length: ns.length))
            .map { m in
                let name = ns.substring(with: m.range(at: 1)).lowercased()
                return Placeholder(range: m.range, name: name,
                                   known: knownKeys.contains(name))
            }
    }

    static func expand(_ template: String, _ ctx: Context) -> String {
        let name = ctx.recipientName.trimmingCharacters(in: .whitespaces)
        let values: [String: String] = [
            "name": name,
            "first_name": firstName(of: name),
            "last_name": name.split(separator: " ").dropFirst().joined(separator: " "),
            "email": ctx.recipientEmail,
            "date": ctx.date,
            "my_name": ctx.myName,
            "my_first_name": firstName(of: ctx.myName),
            "bcc_name": ctx.bccName,
            "bcc_first_name": firstName(of: ctx.bccName),
            "bcc_email": ctx.bccEmail,
        ]
        var result = template
        for (key, value) in values {
            // Double braces first so `{{name}}` is never half-eaten by the
            // single-brace pass; both tolerate inner spaces (Notion style).
            for variant in ["{{\(key)}}", "{{ \(key) }}", "{\(key)}", "{ \(key) }"] {
                result = result.replacingOccurrences(
                    of: variant, with: value, options: .caseInsensitive)
            }
        }
        return result
    }

    private static func firstName(of name: String) -> String {
        name.trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first.map(String.init) ?? ""
    }

    /// Convenience: today's medium-style date string.
    static func today(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}
