import Foundation

/// An address the user can put in the From: header when sending through a
/// given Gmail mailbox. Primary addresses come from linked OAuth accounts;
/// additional rows come from Gmail's "Send mail as" settings on that mailbox.
///
/// Critical split: `email` is the identity shown in From:, while `accountId`
/// is the OAuth mailbox whose API client must be used (and whose threadIds
/// are valid). Confusing the two is what produced the 404 when replying from
/// a second linked account into a thread owned by the first.
struct SendIdentity: Identifiable, Hashable, Codable {
    /// Stable id: mailbox + lowercased email (same address can exist as a
    /// primary on one account and a send-as on another).
    var id: String { "\(accountId.lowercased())|\(email.lowercased())" }

    /// Address written into the MIME From: header.
    let email: String
    /// Display name from Gmail sendAs (or account.senderName for primaries).
    let displayName: String
    /// OAuth mailbox that owns this identity — always use this for GmailClient
    /// and for threadId scoping.
    let accountId: String
    let isPrimary: Bool
    let isDefault: Bool

    /// "Ron Boger <ron@…>" or bare email when no name is set.
    var fromHeader: String {
        let name = displayName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return email }
        return "\(name) <\(email)>"
    }
}

/// Pure helpers for which From identities to offer and which mailbox sends.
/// Kept free of UI / network so unit tests cover the reply-vs-compose rules.
enum SendIdentityResolver {

    /// Identities available in the From picker.
    /// - `mailboxAccountId == nil`: new compose — every identity.
    /// - non-nil (reply/forward/draft in a mailbox): only identities that
    ///   mailbox can send as (primary + its send-as aliases). Never other
    ///   OAuth accounts — their threadIds do not exist in this mailbox.
    static func available(all: [SendIdentity], forMailbox mailboxAccountId: String?) -> [SendIdentity] {
        guard let mailboxAccountId else { return all }
        return all.filter { $0.accountId.caseInsensitiveCompare(mailboxAccountId) == .orderedSame }
    }

    /// Default identity for a mailbox: Gmail's isDefault, else primary, else first.
    static func preferred(_ identities: [SendIdentity], in mailboxAccountId: String) -> SendIdentity? {
        let scoped = available(all: identities, forMailbox: mailboxAccountId)
        return scoped.first(where: \.isDefault)
            ?? scoped.first(where: \.isPrimary)
            ?? scoped.first
    }

    /// Find an identity by email, optionally restricted to one mailbox
    /// (so a send-as on gmail wins over a separate linked account with the
    /// same address when replying in gmail).
    static func identity(email: String, inMailbox mailboxAccountId: String? = nil,
                         from all: [SendIdentity]) -> SendIdentity? {
        let scoped = available(all: all, forMailbox: mailboxAccountId)
        return scoped.first { $0.email.caseInsensitiveCompare(email) == .orderedSame }
            ?? all.first { $0.email.caseInsensitiveCompare(email) == .orderedSame }
    }

    /// API mailbox for a chosen From email. Prefers the mailbox context when
    /// the same address is registered in more than one place.
    static func accountId(for fromEmail: String, inMailbox mailboxAccountId: String? = nil,
                          identities: [SendIdentity], fallback: String) -> String {
        identity(email: fromEmail, inMailbox: mailboxAccountId, from: identities)?.accountId
            ?? fallback
    }

    /// Build the identity list for one account from Gmail sendAs rows.
    /// Unverified aliases are dropped (Gmail would reject them on send).
    /// When the API returns nothing usable, fall back to a synthetic primary.
    static func identities(accountId: String, senderName: String,
                           sendAs: [GSendAs]) -> [SendIdentity] {
        let usable = sendAs.filter { row in
            if row.isPrimary == true { return true }
            return (row.verificationStatus ?? "").lowercased() == "accepted"
        }
        if usable.isEmpty {
            return [SendIdentity(email: accountId, displayName: senderName,
                                 accountId: accountId, isPrimary: true, isDefault: true)]
        }
        return usable.map { row in
            let email = row.sendAsEmail
            let name = (row.displayName ?? "").trimmingCharacters(in: .whitespaces)
            let display = name.isEmpty && (row.isPrimary == true) ? senderName : name
            return SendIdentity(
                email: email,
                displayName: display,
                accountId: accountId,
                isPrimary: row.isPrimary == true,
                isDefault: row.isDefault == true)
        }
    }

    /// When several identities share the same email across mailboxes, the
    /// menu needs a disambiguating label.
    static func menuTitle(_ identity: SendIdentity, all: [SendIdentity]) -> String {
        let email = identity.email
        let ambiguous = all.filter { $0.email.caseInsensitiveCompare(email) == .orderedSame }.count > 1
        let name = identity.displayName.trimmingCharacters(in: .whitespaces)
        if ambiguous {
            let via = "via \(identity.accountId)"
            return name.isEmpty ? "\(email) (\(via))" : "\(name) — \(email) (\(via))"
        }
        if name.isEmpty || name.caseInsensitiveCompare(email) == .orderedSame {
            return email
        }
        return "\(name) — \(email)"
    }

    /// Mailbox whose Gmail API must be used for this send.
    /// Threaded replies and draft edits always stay on the message's account
    /// so threadIds are valid; brand-new mail uses `requested`.
    static func apiAccountId(requested: String, replyAccountId: String?,
                             draftAccountId: String?) -> String {
        if let replyAccountId { return replyAccountId }
        if let draftAccountId { return draftAccountId }
        return requested
    }

    /// Which mailbox (if any) the compose From menu should lock to.
    /// - Restore of a reply/forward/draft-edit: lock to that mailbox.
    /// - Restore of brand-new mail: no lock (user had full From choice).
    /// - Live draft / reply / forward: lock to the message's mailbox.
    static func fixedMailboxAccountId(restoreAccountId: String?,
                                      restoreIsThreaded: Bool,
                                      draftAccountId: String?,
                                      originalAccountId: String?) -> String? {
        if let restoreAccountId {
            return restoreIsThreaded ? restoreAccountId : nil
        }
        if let draftAccountId { return draftAccountId }
        return originalAccountId
    }
}
