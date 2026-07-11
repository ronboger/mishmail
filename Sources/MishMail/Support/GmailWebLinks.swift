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
}
