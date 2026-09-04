import Foundation
import SwiftUI
import AppKit
import GRDB

extension MailStore {
    // MARK: - Sync

    /// Async so the catch-up read is awaited rather than left running in an
    /// untracked task. Termination cancels and awaits every *tracked*
    /// background task before closing SQLCipher; a stray read outliving that
    /// is the exact race `DatabaseLifecycle` exists to prevent.
    func startPolling() async {
        // Demo mode has no real account and no token; polling would only spin
        // up failed syncs and error banners over the screenshot fixtures.
        if demoMode { return }
        guard !isShuttingDown else { return }
        // Catch snoozes that came due while the app was closed.
        await fireDueSnoozes()
        guard !isShuttingDown else { return }
        observeActivityForPolling()
        armSyncTimer()
    }

    private var currentPollInterval: TimeInterval {
        PollCadence.interval(
            appActive: NSApp?.isActive ?? true,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
    private func armSyncTimer() {
        guard !isShuttingDown else { return }
        let interval = currentPollInterval
        syncTimer?.invalidate()
        syncTimerInterval = interval
        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isShuttingDown else { return }
                // Two independent one-at-a-time guards: a long syncAll must
                // not skip due sweeps, and a slow sweep must not stack
                // concurrent fireDue* against itself. Do not clobber a
                // running task (would leave its pool work untracked for
                // termination).
                if self.syncTickTask == nil {
                    self.syncTickTask = Task { @MainActor [weak self] in
                        guard let self else { return }
                        defer { self.syncTickTask = nil }
                        guard !self.isShuttingDown else { return }
                        await self.syncAll(interactive: false)
                    }
                }
                // Due sweeps are independent of syncAll and do not wait for
                // it — reminders, snoozes, and the scheduled-send backstop
                // must still fire on schedule during a long backfill.
                if self.dueSweepTask == nil {
                    self.dueSweepTask = Task { @MainActor [weak self] in
                        guard let self else { return }
                        defer { self.dueSweepTask = nil }
                        guard !self.isShuttingDown else { return }
                        await self.fireDueReminders()
                        await self.fireDueSnoozes()
                        // Backstop for the one-shot timer (sleep/wake can eat it).
                        await self.fireDueScheduledSends()
                    }
                }
            }
        }
    }

    /// Re-arm only when the cadence actually changed. Focus flaps between two
    /// windows of the same app do not change `NSApp.isActive`, but Low Power
    /// Mode and app switches do.
    private func rearmSyncTimerIfCadenceChanged() {
        guard syncTimer != nil, !isShuttingDown else { return }
        guard currentPollInterval != syncTimerInterval else { return }
        armSyncTimer()
    }

    private func observeActivityForPolling() {
        guard activityObservers.isEmpty else { return }
        let center = NotificationCenter.default
        // Coming to the front: catch up now rather than making the user look
        // at a list that can be a whole interval stale, then speed back up.
        activityObservers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isShuttingDown else { return }
                self.rearmSyncTimerIfCadenceChanged()
                // Only if the mailbox is actually stale. Without this floor,
                // alt-tabbing back and forth would fire a full multi-account
                // sync per switch — more requests against Gmail's quota than
                // the poll it is supposed to be relieving.
                if let last = self.lastSyncAttemptedAt,
                   Date().timeIntervalSince(last) < PollCadence.active {
                    return
                }
                await self.syncAll(interactive: false)
            }
        })
        for name in [NSApplication.didResignActiveNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange] {
            activityObservers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.rearmSyncTimerIfCadenceChanged() }
            })
        }
    }

    func stopObservingActivityForPolling() {
        for observer in activityObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        activityObservers.removeAll()
    }

    /// Sync every account with true parallelism at the SyncEngine layer
    /// (each engine is an independent actor). MainActor work — reload,
    /// blocklist, contacts — runs once at the end.
    ///
    /// - Parameter interactive: User-initiated sync (toolbar, menu, banner).
    ///   Background timer / activation catch-up pass `false` so brief offline
    ///   blips do not leave a sticky error banner.
    func syncAll(interactive: Bool = true) async {
        guard !demoMode else {
            syncStatus = ""
            showNotice("Demo inbox is offline")
            return
        }
        guard !isShuttingDown else { return }
        // Covers every exit below, including the no-accounts and early-out
        // paths — all of them count as "we just looked".
        defer { lastSyncAttemptedAt = Date() }
        let ids = accounts.map(\.id)
        guard !ids.isEmpty else {
            await applyBlocklist()
            await notifyNewMail()
            rebuildContacts()
            await autoClassifyNewMail()
            return
        }
        for id in ids where engines[id] == nil {
            engines[id] = SyncEngine(accountId: id)
        }
        // Capture engine refs before leaving MainActor for the task group.
        let pairs: [(String, SyncEngine)] = ids.compactMap { id in
            engines[id].map { (id, $0) }
        }
        syncStatus = ids.count == 1
            ? "Syncing \(ids[0])…"
            : "Syncing \(ids.count) accounts…"

        // Whether any account actually rewrote thread rows this pass.
        // `deriveThreads` is the single choke point for message-row writes and
        // records every key it derives, so `.none` from every engine means the
        // thread table is byte-identical to before the sync — and the whole
        // reload tail below would be recomputing the same answers.
        var anyThreadsChanged = false

        await withTaskGroup(of: (String, Error?, ThreadContentChange).self) { group in
            for (id, engine) in pairs {
                group.addTask {
                    do {
                        let change = try await engine.syncNow { status in
                            Task { @MainActor [weak self] in self?.syncStatus = status }
                        }
                        return (id, nil, change)
                    } catch {
                        // Drain rather than fabricate .none: incrementalSync
                        // may have already rewritten thread rows (deriveThreads
                        // runs before partialFetch is thrown). Skipping the
                        // drain would leave anyThreadsChanged false and the
                        // post-sync reload early-out would hide partial work
                        // until a later clean pass. Matches sync(accountId:).
                        return (id, error, await engine.drainContentChange())
                    }
                }
            }
            for await (id, error, change) in group {
                applyThreadContentChange(change)
                if change != .none { anyThreadsChanged = true }
                if let error {
                    if AccountLifecycle.isReauthRequired(error) {
                        requireReauthorization(for: id)
                    } else if case GmailError.partialFetch = error {
                        // Soft: historyId not advanced; next sync retries.
                        // Still run post-sync so successful upserts appear.
                        accountsNeedingReauth.remove(id)
                        await backfillSenderNameIfNeeded(accountId: id)
                        await refreshSendIdentities(accountId: id)
                    } else if !interactive && TransientNetworkError.isTransient(error) {
                        // Background tick: silent; next poll retries.
                    } else {
                        setSyncFailureError(
                            "\(id): \(error.localizedDescription)",
                            accountId: id)
                    }
                } else {
                    accountsNeedingReauth.remove(id)
                    clearSyncFailureErrorIfNeeded(for: id)
                    await backfillSenderNameIfNeeded(accountId: id)
                    await refreshSendIdentities(accountId: id)
                }
            }
        }
        syncStatus = ""
        // Always: `syncLabels` can rename/add a Gmail label without touching a
        // single thread row, and the sidebar renders from this.
        await reloadAccountsOffMain()
        // The steady state for an idle mailbox is "history returned nothing".
        // Re-running the list query, the blocklist scan, the unread diff and
        // the classifier every 60 seconds to reach the same answer was pure
        // main-actor tax.
        guard anyThreadsChanged else {
            await AppDatabase.shared.checkpointIfNeededOffMain()
            return
        }
        reloadThreads()  // once for all accounts, not once per account
        await applyBlocklist()
        await notifyNewMail()
        rebuildContacts()
        await autoClassifyNewMail()
        await AppDatabase.shared.checkpointIfNeededOffMain()
    }

    func sync(accountId: String) async {
        guard !demoMode else {
            syncStatus = ""
            return
        }
        let engine = engines[accountId] ?? SyncEngine(accountId: accountId)
        engines[accountId] = engine
        syncStatus = "Syncing \(accountId)…"
        do {
            let change = try await engine.syncNow { status in
                Task { @MainActor [weak self] in self?.syncStatus = status }
            }
            applyThreadContentChange(change)
            syncStatus = ""
            accountsNeedingReauth.remove(accountId)
            clearSyncFailureErrorIfNeeded(for: accountId)
            await backfillSenderNameIfNeeded(accountId: accountId)
            await refreshSendIdentities(accountId: accountId)
            reloadAccounts()
            reloadThreads()
        } catch {
            syncStatus = ""
            if AccountLifecycle.isReauthRequired(error) {
                requireReauthorization(for: accountId)
            } else if case GmailError.partialFetch = error {
                // Soft: apply what we got; historyId stays put for retry. The
                // throw skipped syncNow's own drain, so collect the rows that
                // did land rather than leaving them for the next pass.
                applyThreadContentChange(await engine.drainContentChange())
                accountsNeedingReauth.remove(accountId)
                await backfillSenderNameIfNeeded(accountId: accountId)
                await refreshSendIdentities(accountId: accountId)
                reloadAccounts()
                reloadThreads()
            } else {
                setSyncFailureError(
                    "\(accountId): \(error.localizedDescription)",
                    accountId: accountId)
            }
        }
    }

    /// Accounts added before senderName existed get it from the profile.
    private func backfillSenderNameIfNeeded(accountId: String) async {
        // Gate on the published row (senderName is stable there), but never
        // write that value back: published accounts carry lastSyncAt = nil,
        // and a whole-row update would clobber the real timestamp in the DB.
        // Re-fetch inside the write, same as renameAccount / setSenderName.
        guard let published = accounts.first(where: { $0.id == accountId }),
              published.senderName.isEmpty,
              let name = try? await client(for: accountId).userName(),
              !name.isEmpty else { return }
        try? await db.write { db in
            if var account = try Account.fetchOne(db, key: accountId) {
                account.senderName = name
                try account.update(db)
            }
        }
    }

    /// RFC 2822 From value for a mailbox primary (legacy call sites / new
    /// mail default). Prefer `fromHeader(accountId:fromEmail:)` when a
    /// send-as identity may be selected.
    func fromHeader(for accountId: String) -> String {
        fromHeader(accountId: accountId, fromEmail: accountId)
    }

    /// RFC 2822 From for a chosen identity. Uses the send-as display name
    /// when present; falls back to the account's senderName for primaries.
    func fromHeader(accountId: String, fromEmail: String) -> String {
        let email = fromEmail.isEmpty ? accountId : fromEmail
        if let identity = SendIdentityResolver.identity(
            email: email, inMailbox: accountId, from: sendIdentities) {
            return identity.fromHeader
        }
        // Identity list not loaded yet, or email is the primary: use the
        // account's senderName when we have one (covers send-as scheduled
        // sends that fire before refreshSendIdentities finishes).
        if let account = accounts.first(where: { $0.id == accountId }),
           !account.senderName.isEmpty {
            return "\(account.senderName) <\(email)>"
        }
        return email
    }

    // MARK: - New-mail notifications

    /// Ids only — `fetchAll().map(\.id)` decoded every column of every unread
    /// inbox thread (participants, snippet, label blob) just to throw all of
    /// it away. `select` pushes the projection into SQL, so SQLCipher only
    /// decrypts the pages the id index actually needs.
    private func currentUnreadInboxIds() async -> Set<String> {
        let pool = db
        return Set((try? await pool.read { db -> [String] in
            // Primary-tab unread only. Starred promo/social can appear in the
            // inbox *list* (CategoryHide pin-through) but do not notify — a
            // star is a list pin, not a reclassification into Primary.
            // Match primary badge / inbox list: skip actively snoozed rows so
            // a sleeping unread does not notify or seed the baseline.
            // Explicit return: multi-statement closure (let now) loses Swift's
            // single-expression implicit return.
            let now = Date()
            return try MailThread
                .filter(Column("isUnread") == true)
                .filter(Column("inInbox") == true)
                .filter(Column("inTrash") == false)
                .filter(Column("inSpam") == false)
                .filter(Column("inPromotions") == false)
                .filter(Column("inSocial") == false)
                .filter(Column("snoozeUntil") == nil || Column("snoozeUntil") <= now)
                .select(Column("id"), as: String.self)
                .fetchAll(db)
        }) ?? [])
    }
    /// Adopts `current` as "already known", so none of it notifies.
    private func adoptUnreadBaseline(_ current: Set<String>) {
        knownUnreadInboxIds = current
        notifiedThreadIds = current
        unreadBaselineSeeded = true
    }

    /// Seeds the notification baseline without notifying. Runs off the launch
    /// critical path; a sync that beats it is handled by the same flag.
    func seedUnreadBaseline() async {
        guard !unreadBaselineSeeded else { return }
        let current = await currentUnreadInboxIds()
        guard !unreadBaselineSeeded else { return }   // a sync won the race
        adoptUnreadBaseline(current)
    }

    private func notifyNewMail() async {
        let current = await currentUnreadInboxIds()
        guard unreadBaselineSeeded else {
            adoptUnreadBaseline(current)
            return
        }
        let fresh = current.subtracting(notifiedThreadIds)
        notifiedThreadIds.formUnion(current)
        knownUnreadInboxIds = current
        guard !fresh.isEmpty else { return }
        let pool = db
        let newThreads = (try? await pool.read { db in
            try MailThread.filter(fresh.contains(Column("id"))).order(Column("lastDate").desc).fetchAll(db)
        }) ?? []
        for thread in newThreads.prefix(3) {
            Notifier.notify(title: thread.fromDisplay,
                            body: thread.subject.isEmpty ? thread.snippet : thread.subject,
                            id: "mail.\(thread.id)")
        }
        if newThreads.count > 3 {
            Notifier.notify(title: "MishMail", body: "\(newThreads.count) new messages", id: "mail.batch")
        }
    }
}
