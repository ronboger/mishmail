import AppKit
import Foundation

/// Become (and detect) the system default handler for `mailto:` links, and
/// parse those URLs into compose prefills. Parse helpers are pure so unit
/// tests don't need LaunchServices or a running app.
enum DefaultMailClient {

    static let mailtoScheme = "mailto"

    /// Display name for Settings copy (Debug builds say "MishMail Debug").
    static var appDisplayName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "MishMail"
    }

    /// Bundle id currently registered for `mailto:`, if LaunchServices knows one.
    static func currentHandlerBundleID() -> String? {
        guard let url = URL(string: "mailto:probe@example.com"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            return nil
        }
        return Bundle(url: appURL)?.bundleIdentifier
    }

    static var isDefault: Bool {
        guard let mine = Bundle.main.bundleIdentifier,
              let handler = currentHandlerBundleID() else { return false }
        return handler.caseInsensitiveCompare(mine) == .orderedSame
    }

    /// Ask LaunchServices to route `mailto:` to this app. macOS may still
    /// show a system confirmation; failures surface via the completion error.
    static func makeDefault(completion: @escaping (Error?) -> Void) {
        // Prefer trailing-closure form — the labeled `completionHandler:`
        // argument is not accepted by the current AppKit Swift overlay.
        NSWorkspace.shared.setDefaultApplication(
            at: Bundle.main.bundleURL,
            toOpenURLsWithScheme: mailtoScheme) { error in
                completion(error)
            }
    }

    // MARK: - mailto: parse

    struct Mailto: Equatable {
        var to: [String]
        var cc: [String]
        var bcc: [String]
        var subject: String?
        var body: String?
    }

    /// Parse a `mailto:` URL into address lists + optional subject/body.
    /// Returns nil when the scheme isn't mailto (case-insensitive).
    static func parseMailto(_ url: URL) -> Mailto? {
        parseMailto(url.absoluteString)
    }

    /// String entry point for tests (and cold-start open-url payloads).
    static func parseMailto(_ string: String) -> Mailto? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = trimmed.firstIndex(of: ":") else { return nil }
        let scheme = trimmed[..<schemeEnd]
        guard scheme.caseInsensitiveCompare(mailtoScheme) == .orderedSame else {
            return nil
        }
        let afterScheme = trimmed[trimmed.index(after: schemeEnd)...]
        // Split address path from query. First `?` only — body may contain `?`.
        let path: Substring
        let query: Substring?
        if let q = afterScheme.firstIndex(of: "?") {
            path = afterScheme[..<q]
            query = afterScheme[afterScheme.index(after: q)...]
        } else {
            path = afterScheme
            query = nil
        }

        var to = splitAddresses(percentDecode(String(path)))
        var cc: [String] = []
        var bcc: [String] = []
        var subject: String?
        var body: String?

        if let query {
            for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = percentDecode(String(parts[0])).lowercased()
                // `+` in query values is a legacy form-encoding space (RFC 1866);
                // real `+` in addresses should already be percent-encoded as %2B.
                let rawValue = parts.count > 1 ? String(parts[1]) : ""
                let value = percentDecode(rawValue.replacingOccurrences(of: "+", with: " "))
                switch key {
                case "to":
                    to.append(contentsOf: splitAddresses(value))
                case "cc":
                    cc.append(contentsOf: splitAddresses(value))
                case "bcc":
                    bcc.append(contentsOf: splitAddresses(value))
                case "subject":
                    subject = value
                case "body":
                    body = value
                default:
                    break
                }
            }
        }

        return Mailto(
            to: uniquedEmails(to),
            cc: uniquedEmails(cc),
            bcc: uniquedEmails(bcc),
            subject: subject,
            body: body)
    }

    // MARK: - internals

    private static func percentDecode(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }

    /// Comma-separated address list (RFC 6068); keep tokens that look like
    /// emails. Empty path / empty query values yield an empty array.
    private static func splitAddresses(_ raw: String) -> [String] {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        return cleaned
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { extractEmail(String($0)) }
            .filter { !$0.isEmpty && $0.contains("@") }
    }

    /// `"Name <a@b.com>"` → `a@b.com`; bare address kept as-is.
    private static func extractEmail(_ token: String) -> String {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = t.firstIndex(of: "<"),
           let end = t.firstIndex(of: ">"),
           start < end {
            return String(t[t.index(after: start)..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    private static func uniquedEmails(_ emails: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for e in emails {
            let key = e.lowercased()
            if seen.insert(key).inserted { out.append(e) }
        }
        return out
    }
}
