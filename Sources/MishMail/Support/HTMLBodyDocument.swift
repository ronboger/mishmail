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
enum HTMLBodyDocument {
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

    /// Insert `injection` immediately after the opening `<head…>` tag.
    /// If there is no head, insert a head after `<html…>` (or wrap entirely).
    static func injectIntoHead(_ html: String, injection: String) -> String {
        if let range = html.range(of: #"<head\b[^>]*>"#,
                                  options: [.regularExpression, .caseInsensitive]) {
            var out = html
            out.replaceSubrange(range, with: String(html[range]) + injection)
            return out
        }
        if let range = html.range(of: #"<html\b[^>]*>"#,
                                  options: [.regularExpression, .caseInsensitive]) {
            var out = html
            out.replaceSubrange(range,
                                with: String(html[range]) + "<head>\(injection)</head>")
            return out
        }
        // Complete-document detector fired on head+body without html — wrap.
        return "<html><head>\(injection)</head><body>\(html)</body></html>"
    }
}
