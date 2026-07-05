import Foundation

/// Expands `{{variable}}` placeholders in a snippet body. Pure and
/// case-insensitive on the variable name; unknown placeholders are left as-is.
/// Supported: name, first_name, last_name, email, date.
enum SnippetExpander {
    struct Context {
        var recipientName: String = ""
        var recipientEmail: String = ""
        var date: String = ""
    }

    static func expand(_ template: String, _ ctx: Context) -> String {
        let name = ctx.recipientName.trimmingCharacters(in: .whitespaces)
        let parts = name.split(separator: " ")
        let values: [String: String] = [
            "name": name,
            "first_name": parts.first.map(String.init) ?? "",
            "last_name": parts.dropFirst().joined(separator: " "),
            "email": ctx.recipientEmail,
            "date": ctx.date,
        ]
        var result = template
        for (key, value) in values {
            for variant in ["{{\(key)}}", "{{ \(key) }}"] {
                result = result.replacingOccurrences(
                    of: variant, with: value, options: .caseInsensitive)
            }
        }
        return result
    }

    /// Convenience: today's medium-style date string.
    static func today(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}
