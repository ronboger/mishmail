import Foundation

/// Assembles the document string loaded into the message-pane `WKWebView`.
///
/// Two payload shapes arrive from Gmail:
/// - **Fragments** — body markup only (common for plain/simple mail). Wrap in a
///   synthetic `<html><head>…</head><body>…</body></html>`.
/// - **Complete documents** — full `<!DOCTYPE html>…` / `<html>…` (common for
///   transactional / marketing templates). Inject MishMail CSP + CSS into the
///   existing `<head>` so author stylesheets keep working. Do **not** strip
///   the body out with regex — that loses structure and head styles.
///
/// Head/html discovery is HTML-aware: comments and raw-text elements
/// (`script` / `style` / `title` / `textarea` / `xmp`) are skipped so a
/// decoy `<!-- <head> -->` cannot swallow the CSP injection (Ask-policy
/// privacy bypass).
enum HTMLBodyDocument {
    /// Elements whose contents are raw text until the matching close tag —
    /// a literal `<head>` inside them is not a document head.
    private static let rawTextElements = ["script", "style", "title", "textarea", "xmp"]

    /// True when `html` already looks like a full document rather than a body
    /// fragment. Detection is deliberately cheap and case-insensitive.
    static func isCompleteDocument(_ html: String) -> Bool {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Check a short prefix first (DOCTYPE / <html> almost always lead).
        let prefix = String(trimmed.prefix(256)).lowercased()
        if prefix.contains("<!doctype") { return true }
        if prefix.range(of: #"<html\b"#, options: .regularExpression) != nil {
            return true
        }
        // Rare: preamble comments before <html>, or head+body without a
        // leading html tag in the first 256 chars.
        let lower = trimmed.lowercased()
        if lower.range(of: #"<html\b"#, options: .regularExpression) != nil {
            return true
        }
        return lower.contains("<head") && lower.contains("<body")
    }

    /// Build the final HTML string for `loadHTMLString`.
    ///
    /// - Parameters:
    ///   - html: Message body HTML (fragment or complete document).
    ///   - cspMeta: CSP `<meta http-equiv=…>` tag from `HTMLBodyCSP`.
    ///   - styleCSS: Stylesheet *contents* (no outer `<style>` tags) from
    ///     `HTMLBodyDarkMode.injectedCSS` (includes layout image rules).
    static func assemble(html: String, cspMeta: String, styleCSS: String) -> String {
        let styleTag = "<style>\n\(styleCSS)\n</style>"
        let injection = cspMeta + styleTag
        if isCompleteDocument(html) {
            return injectIntoHead(html, injection: injection)
        }
        return "<html><head>\(injection)</head><body>\(html)</body></html>"
    }

    /// Insert `injection` immediately after the first *real* opening `<head…>`
    /// tag (not inside comments / raw-text). If there is no head, insert a
    /// head after the first real `<html…>` (or wrap entirely).
    static func injectIntoHead(_ html: String, injection: String) -> String {
        if let range = rangeOfOpeningTag("head", in: html) {
            var out = html
            out.replaceSubrange(range, with: String(html[range]) + injection)
            return out
        }
        if let range = rangeOfOpeningTag("html", in: html) {
            var out = html
            out.replaceSubrange(range,
                                with: String(html[range]) + "<head>\(injection)</head>")
            return out
        }
        // Complete-document detector fired on head+body without a parseable
        // open tag — wrap so CSP still applies.
        return "<html><head>\(injection)</head><body>\(html)</body></html>"
    }

    /// Range of the first opening tag named `name` that is not inside an HTML
    /// comment or a raw-text element. Exposed for unit tests.
    static func rangeOfOpeningTag(_ name: String, in html: String) -> Range<String.Index>? {
        let chars = Array(html)
        guard !chars.isEmpty else { return nil }
        let target = name.lowercased()
        var i = 0
        let n = chars.count

        while i < n {
            if chars[i] != "<" {
                i += 1
                continue
            }
            // HTML comment: <!-- ... --> (includes conditional comments).
            if startsWith("<!--", at: i, in: chars) {
                i = indexAfter("-->", from: i + 4, in: chars) ?? n
                continue
            }
            // Closing tag — skip.
            if i + 1 < n, chars[i + 1] == "/" {
                i = indexAfter(">", from: i + 2, in: chars) ?? n
                continue
            }
            // Doctype / processing instruction / bogus comment.
            if i + 1 < n, chars[i + 1] == "!" || chars[i + 1] == "?" {
                i = indexAfter(">", from: i + 2, in: chars) ?? n
                continue
            }

            guard let (tagName, tagEnd) = readOpenTagName(at: i, in: chars) else {
                i += 1
                continue
            }

            if tagName == target {
                // Full open tag ends at `>` (or end of string).
                let close = indexAfter(">", from: i + 1, in: chars) ?? n
                let start = html.index(html.startIndex, offsetBy: i)
                let end = html.index(html.startIndex, offsetBy: close)
                return start..<end
            }

            if rawTextElements.contains(tagName) {
                // Skip contents until matching close tag (case-insensitive).
                let afterOpen = indexAfter(">", from: i + 1, in: chars) ?? n
                i = indexAfterRawTextClose(tagName, from: afterOpen, in: chars)
                continue
            }

            i = indexAfter(">", from: i + 1, in: chars) ?? n
        }
        return nil
    }

    // MARK: - Scanner helpers

    private static func startsWith(_ needle: String, at i: Int, in chars: [Character]) -> Bool {
        let n = Array(needle)
        guard i + n.count <= chars.count else { return false }
        for (k, c) in n.enumerated() {
            if chars[i + k] != c { return false }
        }
        return true
    }

    /// Index just past the first occurrence of `needle` starting at `from`,
    /// or `nil` if not found.
    private static func indexAfter(_ needle: String, from: Int, in chars: [Character]) -> Int? {
        let n = Array(needle)
        guard !n.isEmpty else { return from }
        var i = from
        let limit = chars.count - n.count
        while i <= limit {
            var match = true
            for (k, c) in n.enumerated() {
                if chars[i + k] != c {
                    match = false
                    break
                }
            }
            if match { return i + n.count }
            i += 1
        }
        return nil
    }

    /// Parse tag name at a position that points at `<`. Returns lowercased
    /// name and index of the first char after the name.
    private static func readOpenTagName(at lt: Int, in chars: [Character])
        -> (name: String, nameEnd: Int)? {
        var i = lt + 1
        guard i < chars.count else { return nil }
        // Optional whitespace is not valid before tag name in HTML open tags;
        // skip if present for resilience.
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        let nameStart = i
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace || c == ">" || c == "/" { break }
            // Attribute start without space (rare) — stop at non-name char.
            if c == "=" { break }
            i += 1
        }
        guard i > nameStart else { return nil }
        let name = String(chars[nameStart..<i]).lowercased()
        // Must be a plausible tag name ([a-z][a-z0-9:-]*).
        guard name.first?.isLetter == true else { return nil }
        return (name, i)
    }

    /// After the open tag of a raw-text element, find the index past
    /// `</tagName>` (case-insensitive). If missing, consume to end.
    private static func indexAfterRawTextClose(_ tagName: String, from: Int,
                                               in chars: [Character]) -> Int {
        let close = "</\(tagName)"
        let closeChars = Array(close.lowercased())
        var i = from
        let limit = chars.count - closeChars.count
        while i <= limit {
            var match = true
            for (k, c) in closeChars.enumerated() {
                if chars[i + k].lowercased() != c {
                    match = false
                    break
                }
            }
            if match {
                // Ensure boundary after name (>, whitespace, /).
                let after = i + closeChars.count
                if after >= chars.count { return chars.count }
                let b = chars[after]
                if b == ">" || b.isWhitespace || b == "/" {
                    return indexAfter(">", from: after, in: chars) ?? chars.count
                }
            }
            i += 1
        }
        return chars.count
    }
}

private extension Character {
    func lowercased() -> Character {
        Character(String(self).lowercased())
    }
}
