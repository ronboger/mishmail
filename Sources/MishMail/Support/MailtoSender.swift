import Foundation

/// Pure helpers behind `MailStore.mailboxForCorrespondents`: which addresses
/// from a `mailto:` are worth looking up, and how to quote them for `LIKE`.
enum MailtoSender {

    /// Lowercased, de-duplicated recipient addresses that are real emails
    /// and not one of the user's own (mailing yourself says nothing about
    /// which mailbox to send from). Order is preserved.
    static func lookupAddresses(_ addresses: [String], own: Set<String>) -> [String] {
        let ownLower = Set(own.map { $0.lowercased() })
        var seen = Set<String>()
        var out: [String] = []
        for raw in addresses {
            let email = MessageParser.emailAddress(raw).lowercased()
            guard email.contains("@"), !ownLower.contains(email),
                  seen.insert(email).inserted else { continue }
            out.append(email)
        }
        return out
    }

    /// Escape `LIKE` metacharacters so `a_b%c@x.com` matches literally.
    /// Pairs with `ESCAPE '\'` in the query.
    static func likeEscaped(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch == "\\" || ch == "%" || ch == "_" { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}
