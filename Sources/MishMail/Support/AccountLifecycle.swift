import Foundation

/// Account connect / disconnect / reauth policy, kept off `MailStore` so the
/// hostless suite can cover the decisions without AppKit.
enum AccountLifecycle {
    static let demoConnectBlockedMessage =
        "The developer demo cannot connect real accounts. Quit it, configure free Personal Team signing, then run make run DEMO=0."

    /// True when `error` means the account's saved sign-in was rejected by
    /// Google and only reauthorizing (not a retry) can fix it.
    static func isReauthRequired(_ error: Error) -> Bool {
        switch error {
        case OAuthError.invalidGrant: return true
        case GmailError.noRefreshToken: return true
        default: return false
        }
    }

    /// Demo / UI-test processes are Keychain-free. Never let real OAuth data
    /// cross that boundary.
    static func blocksDemoConnect(usesFixtureDatabaseKey: Bool) -> Bool {
        usesFixtureDatabaseKey
    }

    /// Reauthorizing an existing account must only replace its refresh token.
    /// Preserve the history cursor and last-sync timestamp so a bundle-id
    /// migration (or a revoked token) does not trigger a full mailbox
    /// backfill and burn through Gmail's per-user quota.
    static func accountAfterSignIn(
        email: String, name: String?, existing: Account?
    ) -> Account {
        if var existing {
            if existing.displayName == existing.id,
               let name, !name.isEmpty {
                existing.displayName = name
            }
            if existing.senderName.isEmpty {
                existing.senderName = name ?? ""
            }
            return existing
        }
        return Account(
            id: email,
            displayName: name ?? email,
            historyId: nil,
            lastSyncAt: nil,
            senderName: name ?? ""
        )
    }
}
