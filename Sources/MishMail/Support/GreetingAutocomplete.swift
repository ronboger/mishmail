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

    /// Warmth of the message being replied to — steers the empty-body default
    /// opener (and the order used when the typed prefix is ambiguous).
    enum Tone: Equatable {
        /// Casual prior mail → prefer `Hey`.
        case casual
        /// Default / mixed signals → `Hi`.
        case neutral
        /// Formal prior mail → prefer `Hello`.
        case formal
    }

    /// Openers tried in preference order for a neutral empty body
    /// (`"H"` matches Hi before Hello).
    static let openers = ["Hi", "Hey", "Hello"]

    /// Openers ordered for a tone: empty body + ambiguous `"H"`/`"He"` pick
    /// the first match in this list.
    static func openers(for tone: Tone) -> [String] {
        switch tone {
        case .casual: return ["Hey", "Hi", "Hello"]
        case .neutral: return ["Hi", "Hey", "Hello"]
        case .formal: return ["Hello", "Hi", "Hey"]
        }
    }

    /// First whitespace-delimited token of a display name.
    static func firstName(of name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
    }

    /// Role / shared-mailbox labels that must not become "Hi Backoffice,".
    /// Matched case-insensitively against a full display name or any token of
    /// it / the email local-part (whitespace, dots, underscores, hyphens split).
    static let genericMailboxLabels: Set<String> = [
        "backoffice", "back-office", "back_office",
        "noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "do_not_reply",
        "support", "help", "helpdesk", "help-desk",
        "info", "admin", "sales", "billing", "hello", "contact", "contacts",
        "team", "mail", "office", "ops", "hr", "finance", "accounting",
        "notifications", "notification", "alerts", "newsletter", "news",
        "mailer-daemon", "mailerdaemon", "postmaster", "daemon",
        "accounts", "account", "service", "services", "customerservice",
        "customer-service", "customersuccess", "success",
        "robot", "bot", "system", "automated", "auto",
    ]

    /// True when `name` is safe to put after Hi/Hey (not empty, not email-shaped,
    /// not a role/shared mailbox like Backoffice / Support / noreply).
    static func isUsablePersonName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return false }
        // Full addresses and "John@host" local+domain tokens must not become
        // "Hi John@ormoni.bio," — contacts used to store those as display names.
        if n.contains("@") { return false }
        // Undecoded RFC 2047 encoded-words (`=?UTF-8?B?...?=`) must not leak
        // into the ghost if a From header ever arrives un-decoded.
        if n.contains("=?") { return false }
        if isGenericMailboxLabel(n) { return false }
        return true
    }

    /// True for role mailboxes ("Backoffice", "Customer Support", "no-reply").
    static func isGenericMailboxLabel(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        if genericMailboxLabels.contains(lower) { return true }
        // Split "Customer Support" / "no-reply" / "mailer.daemon" into tokens.
        // Any role token is enough — "Customer Support" should not become a
        // greeting first name even though "Customer" alone is fine.
        let tokens = lower
            .split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "_" || $0 == "-" })
            .map(String.init)
        return tokens.contains(where: { genericMailboxLabels.contains($0) })
    }

    /// Name + email from a recipient token (`"Alice <a@x.com>"` or bare
    /// address). Bare local parts become a title-cased guess (`john.doe` →
    /// `John Doe`) for fallback when no contact display name exists.
    static func person(from token: String) -> (name: String, email: String) {
        if let lt = token.firstIndex(of: "<"), let gt = token.firstIndex(of: ">"), lt < gt {
            let name = String(token[..<lt])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            let email = String(token[token.index(after: lt)..<gt])
            return (name, email)
        }
        let email = token.trimmingCharacters(in: .whitespaces)
        // Keep empty local parts (`@host`) — default split drops empties and
        // would title-case the domain into a fake first name ("X" from @x.com).
        let local = email
            .split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        guard !local.isEmpty else { return ("", email) }
        let name = local
            .split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        return (name, email)
    }

    /// First name for the greeting ghost.
    ///
    /// Preference order:
    /// 1. `headerName` — From display of the message being replied to (last
    ///    sender). Most accurate when contacts only know the bare address.
    /// 2. `contactName` — mined contact display name.
    /// 3. Token display name / local-part title-case guess.
    ///
    /// Never returns email-shaped or role/shared mailbox labels (Backoffice,
    /// Support, noreply, …).
    static func recipientFirstName(token: String,
                                   contactName: String?,
                                   headerName: String? = nil) -> String {
        let (tokenName, _) = person(from: token)
        for candidate in [headerName, contactName, tokenName] {
            guard let candidate, isUsablePersonName(candidate) else { continue }
            let first = firstName(of: candidate)
            if isUsablePersonName(first) { return first }
        }
        return ""
    }

    /// Guess tone from the prior message body (reply target). Looks at the
    /// opening line and a few casual/formal body signals — cheap heuristics,
    /// not an LLM. Empty / unknown → neutral.
    static func tone(ofPreviousBody body: String) -> Tone {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .neutral }

        // Opening line (skip blank / quoted-history noise).
        let firstLine = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty && !$0.hasPrefix(">") && !$0.hasPrefix("On ") })
            .map { String($0) } ?? ""
        let open = firstLine.lowercased()

        // Explicit openers on the first line win.
        if open.hasPrefix("hey") || open.hasPrefix("hiya") || open.hasPrefix("yo ")
            || open == "yo" || open.hasPrefix("yo,") || open.hasPrefix("yo!") {
            return .casual
        }
        if open.hasPrefix("dear ") || open.hasPrefix("dear,") || open.hasPrefix("dear:")
            || open == "hello" || open.hasPrefix("hello ") || open.hasPrefix("hello,")
            || open.hasPrefix("hello!")
            || open.hasPrefix("good morning") || open.hasPrefix("good afternoon")
            || open.hasPrefix("good evening") {
            return .formal
        }
        if open.hasPrefix("hi ") || open.hasPrefix("hi,") || open == "hi"
            || open.hasPrefix("hi!") {
            // "Hi" alone is neutral; body signals may still push casual.
        }

        let sample = String(text.prefix(800)).lowercased()
        var casual = 0
        var formal = 0

        // Casual body markers. Avoid short substrings that hit normal words
        // (e.g. "ty!" inside "party!" / "warranty!").
        for token in ["lol", "haha", "hahaha", "lmao", "omg", "gonna", "wanna",
                      "thx", "thanks!", "can't wait", "so excited"] {
            if sample.contains(token) { casual += 1 }
        }
        if sample.contains("!!") { casual += 1 }
        // Common emoji / informal punctuation clusters.
        for ch in sample.unicodeScalars {
            if ch.value >= 0x1F300 && ch.value <= 0x1FAFF { casual += 1; break }
        }

        // Formal body markers.
        for token in ["best regards", "kind regards", "sincerely", "respectfully",
                      "please find", "pursuant", "to whom it may concern",
                      "looking forward to your response"] {
            if sample.contains(token) { formal += 2 }
        }
        if sample.contains("regards,") || sample.contains("yours truly") {
            formal += 1
        }

        if casual > formal { return .casual }
        if formal > casual { return .formal }
        return .neutral
    }

    /// Greeting templates for a resolved first name, ordered by tone.
    static func templates(firstName: String, tone: Tone = .neutral) -> [String] {
        let name = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUsablePersonName(name) else { return [] }
        // Trailing space so Tab leaves the caret ready to keep typing.
        return openers(for: tone).map { "\($0) \(name), " }
    }

    /// Live ghost suggestion for the authored head (text before any quoted
    /// original). Requires the caret at the end of that head, a non-empty
    /// first name, and a single-line head that is a strict prefix of a
    /// greeting template (or empty → default opener for `tone`).
    static func suggestion(authoredBody: String,
                           caretUTF16: Int,
                           firstName: String,
                           tone: Tone = .neutral) -> Suggestion? {
        let templates = templates(firstName: firstName, tone: tone)
        guard let preferred = templates.first else { return nil }

        // Greetings are a single line at the top of the message.
        guard !authoredBody.contains("\n") else { return nil }

        let ns = authoredBody as NSString
        // Do not clamp: a caret past the authored head (inside an expanded
        // reply quote) must not pretend it sits at end-of-head, or ghost/Tab
        // hijack mid-quote. Callers pass the head-only string + full-body
        // caret; equality with head length is the "typing the greeting" gate.
        guard caretUTF16 == ns.length else { return nil }

        if authoredBody.isEmpty {
            return Suggestion(full: preferred, ghost: preferred)
        }

        let typedLower = authoredBody.lowercased()
        // First matching opener in tone preference order.
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
