import Foundation
import SwiftUI
import AppKit
import GRDB

extension MailStore {
    // MARK: - Account lifecycle

    func addAccount(reauthorizing hint: String? = nil) {
        // `make run` / UI tests are deliberately Keychain-free, ad-hoc fixture
        // processes backed by a known database key and isolated directory.
        // Never let real OAuth data cross that boundary; relaunching with
        // DEMO=0 requires stable signing before any real account connects.
        guard !AccountLifecycle.blocksDemoConnect(
            usesFixtureDatabaseKey: AppDatabase.usesFixtureDatabaseKey(
                environment: ProcessInfo.processInfo.environment)) else {
            lastError = AccountLifecycle.demoConnectBlockedMessage
            return
        }
        Task {
            do {
                let (refresh, access) = try await OAuthService().signIn(loginHint: hint)
                var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
                req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
                struct UserInfo: Decodable { let email: String; let name: String? }
                let (data, _) = try await URLSession.shared.data(for: req)
                let info = try JSONDecoder().decode(UserInfo.self, from: data)

                // A successful connection replaces the fictional mailbox.
                // Exit only after OAuth succeeds, so cancelling sign-in leaves
                // the user's demo session intact.
                guard !demoMode || exitDemoMode() else { return }

                try Keychain.set(refresh, forKey: "refreshToken.\(info.email)")
                // The shared client may hold an access token from the old
                // sign-in (other scopes, or a different grant).
                await GmailClient.shared(accountEmail: info.email).forgetAccessToken()
                try await db.write { db in
                    let existing = try Account.fetchOne(db, key: info.email)
                    let account = AccountLifecycle.accountAfterSignIn(
                        email: info.email, name: info.name, existing: existing)
                    if existing != nil {
                        try account.update(db)
                    } else {
                        try account.insert(db)
                    }
                }
                accountsNeedingReauth.remove(info.email)
                reloadAccounts()
                await refreshSendIdentities(accountId: info.email)
                // Own addresses are filtered at rank time. The new primary is
                // already in `ownEmailAddresses` before send-as returns, so
                // setSendIdentities sees no change and would not re-rank.
                rerankContacts()
                await sync(accountId: info.email)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func removeAccount(_ id: String) {
        if demoMode, id == DemoSeed.account {
            _ = exitDemoMode()
            return
        }
        let pool = db
        // Stop the account's sync first: a pass still running would write
        // rows for an account that is being deleted. Drop the account from
        // `accounts` now so late sync errors and reauth requests for it are
        // ignored (see `isKnownAccount`).
        let engine = engines[id]
        accounts.removeAll { $0.id == id }
        Task { @MainActor [weak self] in
            await engine?.cancelSync()
            Keychain.delete("refreshToken.\(id)")
            // After the Keychain delete: the next token request finds no
            // refresh token and fails, instead of reusing the cached one.
            await GmailClient.shared(accountEmail: id).forgetAccessToken()
            // The account row and its queued edits, offline drafts, scheduled
            // sends and triage rows go in one transaction.
            let purged = (try? await pool.write { db in
                try AccountLifecycle.purgeAccount(db, id: id)
            }) != nil
            if purged { AccountLifecycle.clearBackfillFlags(accountId: id) }
            guard let self, !self.isShuttingDown else { return }
            // The account's mail cascades away with it; any payload cached for
            // one of its conversations must not outlive the rows behind it.
            self.applyThreadContentChange(.everything)
            self.engines[id] = nil
            self.clients[id] = nil
            self.accountsNeedingReauth.remove(id)
            self.reloadAccounts()
            self.sendIdentities.removeAll { $0.accountId == id }
            self.reloadThreads()
            // The Scheduled and Outbox lists held rows for this account.
            self.reloadScheduledSends()
            self.reloadLocalDrafts()
            // Own-address set changed — drop the weight map and re-mine.
            self.rebuildContacts(forceFull: true)
            await self.reloadPendingThreadOpCount()
        }
    }

    func requireReauthorization(for accountID: String) {
        // A sync that ends after its account was removed must not bring the
        // account back as a reauthorization request.
        guard isKnownAccount(accountID) else { return }
        accountsNeedingReauth.insert(accountID)
        lastErrorSyncAccountId = nil
        presentedError = ErrorRecovery.reauthorizationRequired(for: accountID)
    }

    /// Record a sync failure banner and remember which account set it so a
    /// later success for that account can clear it without wiping send errors.
    func setSyncFailureError(_ message: String, accountId: String) {
        guard isKnownAccount(accountId) else { return }
        lastError = message
        lastErrorSyncAccountId = accountId
    }

    /// True while `accountId` is still in `accounts`. Late results for a
    /// removed account are ignored.
    func isKnownAccount(_ accountId: String) -> Bool {
        accounts.contains { $0.id == accountId }
    }

    func clearSyncFailureErrorIfNeeded(for accountId: String) {
        guard lastErrorSyncAccountId == accountId else { return }
        lastError = nil
        lastErrorSyncAccountId = nil
    }
}
