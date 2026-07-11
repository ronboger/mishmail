import Foundation

/// Pure thread → Markdown export for Share / clipboard / file save.
///
/// Bodies prefer `bodyText`; empty text falls back to a rough HTML strip so
/// HTML-only mail still exports something readable. Attachments are listed by
/// filename only (P0 — no binary embedding).
enum ThreadExporter {

    struct AttachmentRef: Equatable {
        var messageId: String
        var filename: String
    }

    /// Build a single Markdown document for a conversation.
    static func markdown(
        subject: String,
        messages: [Message],
        attachments: [AttachmentRef] = [],
        dateFormatter: DateFormatter = defaultDateFormatter
    ) -> String {
        var lines: [String] = []
        let title = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("# \(title.isEmpty ? "(no subject)" : title)")
        lines.append("")

        if messages.count > 1 {
            lines.append("_\(messages.count) messages_")
            lines.append("")
        }

        let namesByMessage = Dictionary(grouping: attachments, by: \.messageId)
            .mapValues { $0.map(\.filename) }

        for (index, message) in messages.enumerated() {
            if index > 0 {
                lines.append("---")
                lines.append("")
            }

            let who = MessageParser.displayName(fromHeader: message.fromHeader)
            let email = MessageParser.emailAddress(message.fromHeader)
            let when = dateFormatter.string(from: message.date)
            let headingName = who.isEmpty ? email : who
            lines.append("## \(headingName) · \(when)")
            lines.append("")

            // Compact headers for search/paste fidelity.
            if !email.isEmpty {
                lines.append("**From:** \(formatAddress(name: who, email: email))")
            }
            let to = message.toHeader.trimmingCharacters(in: .whitespacesAndNewlines)
            if !to.isEmpty { lines.append("**To:** \(to)") }
            let cc = message.ccHeader.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cc.isEmpty { lines.append("**Cc:** \(cc)") }
            if !to.isEmpty || !cc.isEmpty || !email.isEmpty {
                lines.append("")
            }

            let body = bodyPlain(message)
            if !body.isEmpty {
                lines.append(body)
                lines.append("")
            }

            if let files = namesByMessage[message.id], !files.isEmpty {
                lines.append("**Attachments:**")
                for name in files {
                    lines.append("- \(name)")
                }
                lines.append("")
            }
        }

        // Trim trailing blank lines; keep a single final newline.
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Safe filename for Save as… (`2026-07-11-thread-subject.md`).
    static func suggestedFilename(subject: String, date: Date = Date(),
                                  calendar: Calendar = .current) -> String {
        let y = calendar.component(.year, from: date)
        let m = calendar.component(.month, from: date)
        let d = calendar.component(.day, from: date)
        let prefix = String(format: "%04d-%02d-%02d", y, m, d)
        let slug = slugify(subject)
        let base = slug.isEmpty ? "\(prefix)-email" : "\(prefix)-\(slug)"
        // Keep names short for Finder / vault path limits.
        let clipped = base.count > 80 ? String(base.prefix(80)) : base
        return "\(clipped).md"
    }

    // MARK: - Internals

    static let defaultDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func bodyPlain(_ message: Message) -> String {
        let text = message.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return message.bodyText.trimmingCharacters(in: .newlines) }
        if let html = message.bodyHTML, !html.isEmpty {
            return stripHTML(html)
        }
        return ""
    }

    static func formatAddress(name: String, email: String) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty || n == email { return email }
        return "\(n) <\(email)>"
    }

    /// Filename-safe slug: lowercase, hyphenated, alphanumerics only.
    static func slugify(_ subject: String) -> String {
        let lowered = subject.lowercased()
        var out = ""
        var pendingHyphen = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                if pendingHyphen, !out.isEmpty { out.append("-") }
                pendingHyphen = false
                out.append(ch)
            } else {
                pendingHyphen = true
            }
        }
        return out
    }

    /// Minimal HTML → text for export. Not a browser; good enough for notes.
    static func stripHTML(_ html: String) -> String {
        var s = html
        // Keep "View invoice" style payloads: anchors become Markdown links
        // before tags are stripped.
        s = linkifyAnchors(s)
        // Block boundaries → newlines before tag strip.
        // Note: pattern is `</?tag\b…>` — a stray `#` before the tag name
        // would make the regex match nothing (block tags would stick words).
        let blockTags = ["br", "p", "div", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6"]
        for tag in blockTags {
            s = s.replacingOccurrences(
                of: #"</?\#(tag)\b[^>]*>"#,
                with: "\n",
                options: [.regularExpression, .caseInsensitive])
        }
        // Drop script/style blocks entirely.
        s = s.replacingOccurrences(
            of: #"<script\b[^>]*>[\s\S]*?</script>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(
            of: #"<style\b[^>]*>[\s\S]*?</style>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive])
        // Remaining tags.
        s = s.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: .regularExpression)
        s = s.decodingHTMLEntities()
        // Collapse runs of blank lines.
        while s.contains("\n\n\n") {
            s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `<a href="url">text</a>` → `[text](url)`. Nested tags in the label are
    /// stripped; empty labels fall back to the bare URL.
    static func linkifyAnchors(_ html: String) -> String {
        // Double- or single-quoted href; non-greedy body until </a>.
        let pattern = #"<a\b[^>]*\bhref\s*=\s*(["'])(.*?)\1[^>]*>([\s\S]*?)</a>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }
        let ns = html as NSString
        let matches = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }

        var result = ""
        var cursor = 0
        for match in matches {
            let full = match.range(at: 0)
            guard full.location != NSNotFound else { continue }
            if full.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            }
            let href = ns.substring(with: match.range(at: 2)).decodingHTMLEntities()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var label = ns.substring(with: match.range(at: 3))
            // Strip nested tags from the label only.
            label = label.replacingOccurrences(
                of: #"<[^>]+>"#, with: "", options: .regularExpression)
            label = label.decodingHTMLEntities()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if href.isEmpty {
                result += label
            } else if label.isEmpty {
                result += href
            } else {
                result += "[\(label)](\(href))"
            }
            cursor = full.location + full.length
        }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
    }
}
