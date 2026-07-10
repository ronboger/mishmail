import Foundation

/// Markdown-style hyperlinks for the plain-text compose body.
///
/// Compose stays a `String` (snippets, slash picker, quote collapse all
/// depend on that). Users insert links as `[label](url)` via ⌘K; on send we
/// always emit an HTML alternative that turns those (and bare URLs) into
/// real `<a href>` anchors so recipients get Gmail-style clickable links.
enum ComposeLinks {

    /// A markdown link `[text](url)` found in a compose body.
    struct MarkdownLink: Equatable {
        /// Full span including brackets and parentheses.
        let range: Range<String.Index>
        let text: String
        let url: String
    }

    // MARK: - URL normalization

    /// Accepts http(s)/mailto, bare emails → `mailto:`, bare hosts → `https://`.
    /// Rejects empty input and dangerous schemes (`javascript:`, `data:`, …).
    ///
    /// Scheme detection is conservative: only `http` / `https` / `mailto` are
    /// treated as schemes. That way `example.com:8080` and `example.com/a:b`
    /// fall through to `https://…` instead of being rejected because the
    /// substring before the first `:` looked scheme-like.
    static func normalizeURL(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        // Angle-bracket wrapping is common when pasting from other mail clients.
        if s.hasPrefix("<"), s.hasSuffix(">"), s.count >= 2 {
            s = String(s.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return nil }
        }
        if let colon = s.firstIndex(of: ":") {
            let prefix = String(s[..<colon])
            // Allowlisted schemes only — never treat "example.com" as a scheme.
            if let scheme = recognizedScheme(prefix) {
                if scheme == "mailto" {
                    let address = s[s.index(after: colon)...]
                    guard !address.isEmpty else { return nil }
                }
                return s
            }
            // Pure scheme token (no dots) that we don't allow → reject.
            // host:port / path:with:colons fall through (they contain '.' or '/').
            if isSchemeToken(prefix) { return nil }
        }
        // bare email → mailto
        if s.contains("@"),
           !s.contains(where: { $0.isWhitespace }),
           !s.contains("/") {
            return "mailto:\(s)"
        }
        return "https://\(s)"
    }

    /// `http` / `https` / `mailto` (case-insensitive), else nil.
    private static func recognizedScheme(_ prefix: String) -> String? {
        let scheme = prefix.lowercased()
        guard scheme == "http" || scheme == "https" || scheme == "mailto" else {
            return nil
        }
        return scheme
    }

    /// RFC 3986 scheme shape: `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`,
    /// but we additionally require no `.` so `example.com:8080` is not a scheme.
    private static func isSchemeToken(_ prefix: String) -> Bool {
        guard let first = prefix.first, first.isLetter else { return false }
        return prefix.allSatisfy { ch in
            ch.isLetter || ch.isNumber || ch == "+" || ch == "-"
        }
    }

    // MARK: - ⌘K on an already-linkable selection

    /// The href to use when ⌘K is pressed on a selection that already *is*
    /// a URL/email — lets `openLinkSheet()` skip the sheet and link it
    /// directly instead of making the user retype what they just selected.
    ///
    /// Qualifies only when the (trimmed) selection: is non-empty, has no
    /// internal whitespace/newlines, isn't itself markdown link syntax
    /// (`[text](url)`), `normalizeURL` accepts it, and it plausibly looks
    /// like a URL/email (recognized scheme, contains `@`, or contains `.`).
    /// The last check keeps plain words like "hello" from qualifying even
    /// though `normalizeURL` would happily turn them into `https://hello`.
    static func selfLink(forSelection selected: String) -> String? {
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        // Selecting the raw markdown of an existing link (e.g. dragging over
        // `[foo.com](https://foo.com)`) is not a bare URL to self-link.
        guard markdownLinks(in: trimmed).isEmpty else { return nil }
        guard looksLikeURLOrEmail(trimmed) else { return nil }
        return normalizeURL(trimmed)
    }

    private static func looksLikeURLOrEmail(_ s: String) -> Bool {
        let lower = s.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") {
            return true
        }
        return s.contains("@") || s.contains(".")
    }

    // MARK: - Insert / edit / remove

    /// Replaces `selection` with a markdown link. Display text prefers an
    /// explicit `text`, then the selected substring, then the normalized URL.
    /// Returns nil when the URL is empty or uses a disallowed scheme.
    static func applyLink(in body: String,
                          selection: Range<String.Index>,
                          text: String? = nil,
                          url: String) -> String? {
        guard let href = normalizeURL(url) else { return nil }
        let selected = String(body[selection])
        let label: String = {
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            if !selected.isEmpty { return selected }
            return href
        }()
        // `]` inside the label would break the markdown parse; strip it.
        let safeLabel = label.replacingOccurrences(of: "]", with: "")
        let markdown = "[\(safeLabel)](\(href))"
        var result = body
        result.replaceSubrange(selection, with: markdown)
        return result
    }

    /// The markdown link whose full span contains `cursor` (or ends at it).
    static func link(at cursor: String.Index, in body: String) -> MarkdownLink? {
        guard !body.isEmpty else { return nil }
        let probe = cursor > body.startIndex && cursor == body.endIndex
            ? body.index(before: cursor) : cursor
        guard probe < body.endIndex else { return nil }
        for link in markdownLinks(in: body) {
            if link.range.contains(probe) || link.range.upperBound == cursor {
                return link
            }
        }
        return nil
    }

    /// Replaces `[text](url)` with just `text`.
    static func removeLink(_ link: MarkdownLink, in body: String) -> String {
        var result = body
        result.replaceSubrange(link.range, with: link.text)
        return result
    }

    // MARK: - HTML

    /// Escaped HTML fragment for a plain-text compose body: markdown links and
    /// bare `http(s)://` / `mailto:` URLs become anchors; newlines become `<br>`.
    static func htmlFragment(from plain: String) -> String {
        guard !plain.isEmpty else { return "" }
        var out = ""
        var i = plain.startIndex
        let links = nonOverlappingLinkSpans(in: plain)
        var linkIdx = 0
        while i < plain.endIndex {
            if linkIdx < links.count, links[linkIdx].range.lowerBound == i {
                let span = links[linkIdx]
                let href = escapeAttribute(span.href)
                let label = escapeText(span.label).replacingOccurrences(of: "\n", with: "<br>")
                out += "<a href=\"\(href)\">\(label)</a>"
                i = span.range.upperBound
                linkIdx += 1
                continue
            }
            // Consume plain text up to the next link (or end).
            let end = linkIdx < links.count ? links[linkIdx].range.lowerBound : plain.endIndex
            let chunk = String(plain[i..<end])
            out += escapeText(chunk).replacingOccurrences(of: "\n", with: "<br>")
            i = end
        }
        return out
    }

    // MARK: - UTF-16 bridge (NSTextView selection)

    static func stringRange(nsRange: NSRange, in string: String) -> Range<String.Index>? {
        Range(nsRange, in: string)
    }

    static func nsRange(of range: Range<String.Index>, in string: String) -> NSRange {
        NSRange(range, in: string)
    }

    // MARK: - Internals

    private struct LinkSpan {
        let range: Range<String.Index>
        let label: String
        let href: String
    }

    /// Markdown links first, then bare URLs in the remaining gaps (no overlap).
    private static func nonOverlappingLinkSpans(in body: String) -> [LinkSpan] {
        let md = markdownLinks(in: body).compactMap { link -> LinkSpan? in
            // Always emit the *normalized* href so hand-typed `[x](example.com)`
            // becomes `https://example.com`, not a relative `example.com`.
            guard let href = normalizeURL(link.url) else { return nil }
            return LinkSpan(range: link.range, label: link.text, href: href)
        }
        var occupied = md.map(\.range)
        var bare: [LinkSpan] = []
        for match in bareURLMatches(in: body) {
            if occupied.contains(where: { rangesOverlap($0, match.range) }) { continue }
            bare.append(LinkSpan(range: match.range, label: match.text, href: match.url))
            occupied.append(match.range)
        }
        return (md + bare).sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    static func markdownLinks(in body: String) -> [MarkdownLink] {
        // [label](url) — label may be empty; url has no spaces or closing paren.
        guard let re = try? NSRegularExpression(
            pattern: #"\[([^\]]*)\]\(([^)\s]+)\)"#) else { return [] }
        let ns = body as NSString
        let full = NSRange(location: 0, length: ns.length)
        return re.matches(in: body, range: full).compactMap { match -> MarkdownLink? in
            guard match.numberOfRanges == 3,
                  let fullRange = Range(match.range(at: 0), in: body),
                  let textRange = Range(match.range(at: 1), in: body),
                  let urlRange = Range(match.range(at: 2), in: body) else { return nil }
            let url = String(body[urlRange])
            // Only keep schemes we'd emit as hrefs (or scheme-less hosts).
            guard normalizeURL(url) != nil else { return nil }
            return MarkdownLink(range: fullRange,
                                text: String(body[textRange]),
                                url: url)
        }
    }

    private struct BareURL {
        let range: Range<String.Index>
        let text: String
        let url: String
    }

    private static func bareURLMatches(in body: String) -> [BareURL] {
        guard let re = try? NSRegularExpression(
            pattern: #"(?i)\b((?:https?://|mailto:)[^\s<>\[\]()\"']+)"#) else { return [] }
        let ns = body as NSString
        let full = NSRange(location: 0, length: ns.length)
        return re.matches(in: body, range: full).compactMap { match -> BareURL? in
            guard let range = Range(match.range(at: 1), in: body) else { return nil }
            var text = String(body[range])
            // Trim trailing punctuation commonly stuck to URLs in prose.
            while let last = text.last, ".,;:!?)]}\"'".contains(last) {
                text.removeLast()
            }
            guard !text.isEmpty,
                  let end = body.index(range.lowerBound,
                                       offsetBy: text.count,
                                       limitedBy: range.upperBound),
                  let href = normalizeURL(text) else { return nil }
            return BareURL(range: range.lowerBound..<end, text: text, url: href)
        }
    }

    private static func rangesOverlap(_ a: Range<String.Index>,
                                      _ b: Range<String.Index>) -> Bool {
        a.overlaps(b)
    }

    static func escapeText(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeAttribute(_ s: String) -> String {
        escapeText(s).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
