import Foundation

/// Gmail-style greeting ghost-text for the start of a compose body.
///
/// When the authored head is empty or a case-insensitive prefix of
/// `Hi/Hey/Hello {firstName},`, offer the remainder as grey ghost text and
/// complete the full greeting on Tab. Pure so unit tests can drive matching
/// without AppKit.
enum GreetingAutocomplete {
    /// One live suggestion: the canonical full greeting and the grey suffix
    /// drawn after the caret.
    struct Suggestion: Equatable {
        /// Canonical text after Tab (`"Hi Alice, "`).
        var full: String
        /// Suffix drawn in tertiary label color (empty body → whole `full`).
        var ghost: String
    }

    /// Openers tried in preference order when the body is empty or ambiguous
    /// (`"H"` matches Hi before Hello).
    static let openers = ["Hi", "Hey", "Hello"]

    /// First whitespace-delimited token of a display name.
    static func firstName(of name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").first.map(String.init) ?? ""
    }

    /// Greeting templates for a resolved first name (`"Hi Alice, "` …).
    static func templates(firstName: String) -> [String] {
        let name = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        // Trailing space so Tab leaves the caret ready to keep typing.
        return openers.map { "\($0) \(name), " }
    }

    /// Live ghost suggestion for the authored head (text before any quoted
    /// original). Requires the caret at the end of that head, a non-empty
    /// first name, and a single-line head that is a strict prefix of a
    /// greeting template (or empty → default `Hi {name}, `).
    static func suggestion(authoredBody: String,
                           caretUTF16: Int,
                           firstName: String) -> Suggestion? {
        let templates = templates(firstName: firstName)
        guard let preferred = templates.first else { return nil }

        // Greetings are a single line at the top of the message.
        guard !authoredBody.contains("\n") else { return nil }

        let ns = authoredBody as NSString
        let caret = max(0, min(caretUTF16, ns.length))
        // Only while typing at the end of the head — mid-word caret moves
        // and selections never show ghost text.
        guard caret == ns.length else { return nil }

        if authoredBody.isEmpty {
            return Suggestion(full: preferred, ghost: preferred)
        }

        let typedLower = authoredBody.lowercased()
        // First matching opener in preference order (Hi before Hey/Hello).
        guard let full = templates.first(where: {
            let lower = $0.lowercased()
            return lower.hasPrefix(typedLower) && lower != typedLower
        }) else { return nil }

        let typedLen = ns.length
        let fullNS = full as NSString
        guard fullNS.length > typedLen else { return nil }
        // Remainder keeps template casing; Tab replaces the whole head with
        // `full` so mixed-case typing still lands on the canonical form.
        let ghost = fullNS.substring(from: typedLen)
        return Suggestion(full: full, ghost: ghost)
    }

    /// Body after accepting a suggestion: replace the authored head with
    /// `suggestion.full`, leave any quoted tail untouched.
    static func applying(_ suggestion: Suggestion,
                         toBody body: String,
                         authoredHeadEndUTF16: Int) -> (body: String, caretUTF16: Int) {
        let ns = body as NSString
        let headEnd = max(0, min(authoredHeadEndUTF16, ns.length))
        let tail = ns.substring(from: headEnd)
        let next = suggestion.full + tail
        return (next, (suggestion.full as NSString).length)
    }
}
