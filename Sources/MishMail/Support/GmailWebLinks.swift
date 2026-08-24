import Foundation

/// Deep links into gmail.com that carry the right account via `authuser`.
/// Pure helpers so URL shaping is unit-testable without AppKit.
enum GmailWebLinks {

    /// Encode an email for a query value. Stricter than `.urlQueryAllowed`:
    /// `+` must become `%2B` (form decoding would otherwise turn it into a
    /// space and Gmail would ignore `authuser` / pick the default account).
    static func encodeAuthUser(_ email: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~@")  // unreserved + @ for readability
        return email.addingPercentEncoding(withAllowedCharacters: allowed) ?? email
    }

    static func threadURL(accountEmail: String, gmailThreadId: String) -> URL? {
        let e = encodeAuthUser(accountEmail)
        // Thread id is hex-ish from Gmail; don't percent-encode the fragment
        // path beyond what's needed for a valid URL string.
        return URL(string: "https://mail.google.com/mail/?authuser=\(e)#all/\(gmailThreadId)")
    }

    static func filtersSettingsURL(accountEmail: String) -> URL? {
        let e = encodeAuthUser(accountEmail)
        return URL(string: "https://mail.google.com/mail/?authuser=\(e)#settings/filters")
    }

    /// Pasteboard string for ⌘L / Copy link. A gmail.com conversation URL
    /// that opens in the browser, with `authuser` so a multi-account inbox
    /// lands in the right mailbox. Nil when the ids cannot form a URL.
    static func copyPasteboardString(accountEmail: String,
                                     gmailThreadId: String) -> String? {
        let email = accountEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = gmailThreadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, email.contains("@"), !id.isEmpty,
              !id.contains(where: { $0.isWhitespace }) else { return nil }
        return threadURL(accountEmail: email, gmailThreadId: id)?.absoluteString
    }
}

/// App-owned links used by local tools (including Codex) to open a Gmail
/// message or conversation in MishMail instead of gmail.com.
///
/// The token may be either a Gmail thread id or message id. Resolution lives
/// in `MailStore`, where both tables are available. Keeping URL parsing here
/// makes the accepted surface small and independently testable.
enum MishMailDeepLinks {
    struct ThreadTarget: Equatable {
        let token: String
        let accountEmail: String?
    }

    static func threadURL(accountEmail: String?, token: String) -> URL? {
        guard isValidToken(token) else { return nil }
        if let accountEmail, !isValidAccount(accountEmail) { return nil }
        var components = URLComponents()
        components.scheme = "mishmail"
        components.host = "thread"
        components.path = "/\(token)"
        if let accountEmail {
            components.queryItems = [URLQueryItem(name: "account", value: accountEmail)]
        }
        return components.url
    }

    static func parseThreadURL(_ url: URL) -> ThreadTarget? {
        guard url.scheme?.lowercased() == "mishmail",
              url.host?.lowercased() == "thread" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 1, isValidToken(parts[0]) else { return nil }

        let account = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name.lowercased() == "account" })?
            .value
        if let account, !isValidAccount(account) { return nil }
        return ThreadTarget(token: parts[0], accountEmail: account)
    }

    private static func isValidToken(_ token: String) -> Bool {
        guard !token.isEmpty, token.count <= 256 else { return false }
        return token.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)
        }
    }

    private static func isValidAccount(_ account: String) -> Bool {
        !account.isEmpty && account.count <= 320 && account.contains("@")
            && !account.contains(where: { $0.isWhitespace || $0 == "/" })
    }
}
