import AppKit
import Foundation

/// Become (and detect) the system default handler for `mailto:` links, and
/// parse those URLs into compose prefills. Parse helpers are pure so unit
/// tests don't need LaunchServices or a running app.
enum DefaultMailClient {

    static let mailtoScheme = "mailto"

    enum SelectionError: LocalizedError {
        case didNotChange(currentHandler: String?)

        var errorDescription: String? {
            switch self {
            case .didNotChange(let currentHandler):
                let current = currentHandler.map { " It is still \($0)." } ?? ""
                return "macOS did not change the default email app.\(current) "
                    + "Please approve the system confirmation and try again."
            }
        }
    }

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

    /// Ask LaunchServices to route `mailto:` to this app. macOS may still show
    /// a system confirmation. Verify the resulting handler because a successful
    /// request callback does not guarantee LaunchServices has published the
    /// selection by the time Settings redraws.
    static func makeDefault(completion: @escaping (Error?) -> Void) {
        // Prefer trailing-closure form — the labeled `completionHandler:`
        // argument is not accepted by the current AppKit Swift overlay.
        NSWorkspace.shared.setDefaultApplication(
            at: Bundle.main.bundleURL,
            toOpenURLsWithScheme: mailtoScheme) { error in
                if let error {
                    completion(error)
                    return
                }
                verifyDefault(attemptsRemaining: 5, completion: completion)
            }
    }

    private static func verifyDefault(
        attemptsRemaining: Int,
        completion: @escaping (Error?) -> Void
    ) {
        if isDefault {
            completion(nil)
        } else if attemptsRemaining > 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                verifyDefault(
                    attemptsRemaining: attemptsRemaining - 1,
                    completion: completion)
            }
        } else {
            completion(SelectionError.didNotChange(
                currentHandler: currentHandlerBundleID()))
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
                let rawValue = parts.count > 1 ? String(parts[1]) : ""
                // RFC 6068 has no form-encoding: `+` is a literal plus. Text
                // fields still honor the legacy space reading, because links in
                // the wild are written that way — but addresses must not, or
                // plus-addressed mailboxes (`ron+news@gmail.com`) silently
                // become `ron news@gmail.com` and the send bounces.
                let address = percentDecode(rawValue)
                let text = percentDecode(rawValue.replacingOccurrences(of: "+", with: " "))
                switch key {
                case "to":
                    to.append(contentsOf: splitAddresses(address))
                case "cc":
                    cc.append(contentsOf: splitAddresses(address))
                case "bcc":
                    bcc.append(contentsOf: splitAddresses(address))
                case "subject":
                    subject = text
                case "body":
                    body = text
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

    /// Prefill strings for `ComposeRequest` (comma-joined address lists).
    /// Pure so the join shape is unit-testable without MailStore.
    struct ComposePrefill: Equatable {
        var to: String?
        var cc: String?
        var bcc: String?
        var subject: String?
        var body: String?
    }

    static func composePrefill(from mail: Mailto) -> ComposePrefill {
        func join(_ list: [String]) -> String? {
            list.isEmpty ? nil : list.joined(separator: ", ")
        }
        return ComposePrefill(
            to: join(mail.to),
            cc: join(mail.cc),
            bcc: join(mail.bcc),
            subject: mail.subject,
            body: mail.body)
    }

    // MARK: - internals

    /// Decode percent-escapes. A single malformed `%` must not leave the rest
    /// of the string encoded (`body=100%%20sure` → `100% sure`, not the raw
    /// form). Valid `%HH` runs are preserved; lone `%` becomes a literal `%`.
    private static func percentDecode(_ s: String) -> String {
        if let full = s.removingPercentEncoding { return full }
        // Escape invalid `%` so a second pass can decode the valid sequences.
        var fixed = ""
        fixed.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "%" {
                let h1 = s.index(i, offsetBy: 1, limitedBy: s.endIndex)
                let h2 = s.index(i, offsetBy: 2, limitedBy: s.endIndex)
                if let h1, let h2, h2 < s.endIndex,
                   s[h1].isHexDigit, s[h2].isHexDigit {
                    fixed.append(contentsOf: s[i...h2])
                    i = s.index(after: h2)
                    continue
                }
                fixed.append("%25")  // lone or short `%` → literal after decode
                i = s.index(after: i)
                continue
            }
            fixed.append(s[i])
            i = s.index(after: i)
        }
        return fixed.removingPercentEncoding ?? fixed
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
