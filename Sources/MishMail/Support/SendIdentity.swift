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

    /// Menu / closed-label for a From identity.
    ///
    /// Lead with the email: that's the part that differs when every identity
    /// shares one display name (one person, many domains). A display name
    /// is appended only when names in `all` actually differ. "via mailbox"
    /// is only added when the same address exists on more than one mailbox
    /// *and* the mailbox is a different address — skip
    /// `ron@x.com (via ron@x.com)`.
    static func menuTitle(_ identity: SendIdentity, all: [SendIdentity]) -> String {
        let email = identity.email
        let name = identity.displayName.trimmingCharacters(in: .whitespaces)
        let distinctNames = Set(all.compactMap { row -> String? in
            let n = row.displayName.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { return nil }
            return n.lowercased()
        })
        let nameHelps = !name.isEmpty
            && distinctNames.count > 1
            && name.caseInsensitiveCompare(email) != .orderedSame
        let sameEmailCount = all.filter {
            $0.email.caseInsensitiveCompare(email) == .orderedSame
        }.count
        let mailboxDiffers = email.caseInsensitiveCompare(identity.accountId) != .orderedSame
        let needsVia = sameEmailCount > 1 && mailboxDiffers

        var title = email
        if nameHelps { title += " — \(name)" }
        if needsVia { title += " (via \(identity.accountId))" }
        return title
    }

    /// Stable order for the From menu: domain, then local part, then
    /// primary-of-that-address before a send-as of another mailbox.
    static func sortedForMenu(_ identities: [SendIdentity]) -> [SendIdentity] {
        identities.sorted { a, b in
            let (aDomain, aLocal) = emailSortKey(a.email)
            let (bDomain, bLocal) = emailSortKey(b.email)
            if aDomain != bDomain { return aDomain < bDomain }
            if aLocal != bLocal { return aLocal < bLocal }
            let aVia = a.email.caseInsensitiveCompare(a.accountId) != .orderedSame
            let bVia = b.email.caseInsensitiveCompare(b.accountId) != .orderedSame
            if aVia != bVia { return !aVia }
            return a.accountId.lowercased() < b.accountId.lowercased()
        }
    }

    private static func emailSortKey(_ email: String) -> (String, String) {
        let lower = email.lowercased()
        guard let at = lower.firstIndex(of: "@") else { return (lower, "") }
        return (String(lower[lower.index(after: at)...]), String(lower[..<at]))
    }

    /// Mailbox whose Gmail API must be used for this send.
    ///
    /// Replies stay on the thread's mailbox so Gmail threadIds stay valid.
    /// Brand-new mail — including an autosave draft of a new compose —
    /// honors `requested`. Pinning new mail to `draftAccountId` made a
    /// From change after the first autosave still send through the original
    /// mailbox; Gmail then rewrites From to that mailbox's default send-as.
    /// `draftAccountId` is only a fallback when `requested` is empty.
    static func apiAccountId(requested: String, replyAccountId: String?,
                             draftAccountId: String?) -> String {
        if let replyAccountId { return replyAccountId }
        let chosen = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        if !chosen.isEmpty { return chosen }
        return draftAccountId ?? requested
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
