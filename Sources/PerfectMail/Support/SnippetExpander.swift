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
