import Foundation
import GRDB

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

    /// Accounts a sync pass should attempt. A background pass skips accounts
    /// already known to need reauthorization: only the user can fix those,
    /// and each attempt is a request to Google's token endpoint with a dead
    /// token. A user-initiated pass tries all of them. The flag is cleared by
    /// a successful sign-in or sync, after which polling resumes.
    static func accountsToSync(
        all: [String], needingReauth: Set<String>, interactive: Bool
    ) -> [String] {
        interactive ? all : all.filter { !needingReauth.contains($0) }
    }

    /// Whether a reauthorization failure should raise the banner. Repeat
    /// failures for an account that is already flagged stay quiet, so a
    /// dismissed banner does not return and does not replace an unrelated
    /// one — unless the user asked for the sync that failed.
    static func presentsReauthBanner(newlyFlagged: Bool, interactive: Bool) -> Bool {
        newlyFlagged || interactive
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

    // MARK: - Removal

    /// Deletes the account row and every local row that belongs to it. Call
    /// inside one write transaction so a failure leaves the account whole.
    ///
    /// Mail (threads, messages, bodies, attachments, labels, summaries)
    /// cascades from the account row. The offline queues, scheduled sends and
    /// triage results carry no foreign key and would otherwise outlive it: a
    /// due scheduled send would still try to go out, and a queued edit for a
    /// missing account would sit in the replay queue forever.
    ///
    /// Saved views scoped to the account are kept on purpose. They hold
    /// filter settings, not mail, and the documented fix for a missing Gmail
    /// permission is "remove the account and add it again" — deleting them
    /// would lose hand-built views across that round trip, and clearing the
    /// scope would silently point a label filter at another account's label
    /// with the same id. A kept view is empty until the account returns.
    static func purgeAccount(_ db: Database, id: String) throws {
        for table in ["pendingThreadOp", "localDraft", "scheduledSend"] {
            try db.execute(sql: "DELETE FROM \(table) WHERE accountId = ?",
                           arguments: [id])
        }
        // Thread ids are "<account>:<gmailThreadId>". Not LIKE: `_` and `%`
        // are legal in an address and would match another account's rows.
        let prefix = "\(id):"
        try db.execute(
            sql: "DELETE FROM threadAI WHERE substr(threadId, 1, length(?)) = ?",
            arguments: [prefix, prefix])
        try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [id])
    }

    /// UserDefaults flags that record which one-time backfills an account has
    /// completed. Key strings match `SyncEngine.performSyncNow`.
    static func backfillFlagKeys(accountId: String) -> [String] {
        ["backfill.window.\(accountId)",
         "backfill.starred.\(accountId)",
         SyncEngine.attachmentRepairDefaultsKey(accountId: accountId)]
    }

    /// A removed account's cache is gone, so its "already backfilled" flags
    /// are false. Left in place, adding the account again would skip the
    /// starred-mail backfill.
    static func clearBackfillFlags(accountId: String,
                                   defaults: UserDefaults = .standard) {
        for key in backfillFlagKeys(accountId: accountId) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Scope after removal
    //
    // Primitive types on purpose: `MailboxView` and `BadgeScope` live in the
    // app target, outside the hostless suite.

    /// The single-account filter after `removed` is gone: back to the unified
    /// view when it pointed at that account, unchanged otherwise.
    static func activeAccountAfterRemoval(active: String?, removed: String) -> String? {
        active == removed ? nil : active
    }

    /// True when the selected view shows only `removed`'s mail (its inbox,
    /// one of its labels, or a saved view scoped to it) and would be an
    /// empty list from now on. `viewAccount` is nil for a unified view.
    static func viewIsScopedToRemovedAccount(viewAccount: String?, removed: String) -> Bool {
        viewAccount == removed
    }

    /// The dock-badge scope preference ("all", "focused", "account:<email>")
    /// after `removed` is gone. A scope of the removed account would count
    /// nothing, so it falls back to "all".
    static func badgeScopeRawAfterRemoval(raw: String?, removed: String) -> String? {
        raw == "account:\(removed)" ? "all" : raw
    }
}
