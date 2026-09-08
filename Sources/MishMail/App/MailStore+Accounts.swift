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
        Keychain.delete("refreshToken.\(id)")
        try? db.write { db in _ = try Account.deleteOne(db, key: id) }
        // The account's mail cascades away with it; any payload cached for one
        // of its conversations must not outlive the rows behind it.
        applyThreadContentChange(.everything)
        engines[id] = nil
        clients[id] = nil
        accountsNeedingReauth.remove(id)
        reloadAccounts()
        sendIdentities.removeAll { $0.accountId == id }
        reloadThreads()
        // Own-address set changed — drop the weight map and re-mine.
        rebuildContacts(forceFull: true)
    }

    func requireReauthorization(for accountID: String) {
        accountsNeedingReauth.insert(accountID)
        lastErrorSyncAccountId = nil
        presentedError = ErrorRecovery.reauthorizationRequired(for: accountID)
    }

    /// Record a sync failure banner and remember which account set it so a
    /// later success for that account can clear it without wiping send errors.
    func setSyncFailureError(_ message: String, accountId: String) {
        lastError = message
        lastErrorSyncAccountId = accountId
    }

    func clearSyncFailureErrorIfNeeded(for accountId: String) {
        guard lastErrorSyncAccountId == accountId else { return }
        lastError = nil
        lastErrorSyncAccountId = nil
    }
}
