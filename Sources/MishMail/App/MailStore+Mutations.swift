import Foundation
import SwiftUI
import AppKit
import GRDB

extension MailStore {
    // MARK: - Actions (optimistic local write, then remote, then resync on failure)


    /// Returns the post-action copy. An undo must use it as its base: the
    /// thread write persists only columns that differ from the base (see
    /// `ThreadUndo`).
    @discardableResult
    func mutateThread(_ thread: MailThread,
                      autoAdvanceAction: String? = nil,
                      remote: RemoteThreadChange,
                      local: (inout MailThread) -> Void) -> MailThread {
        guard !isShuttingDown else { return thread }
        var copy = thread
        local(&copy)
        let updated = copy

        // Auto-advance before removing the selected row. `openDetail` changes
        // synchronously for this intent, so there is never a frame where the
        // reading pane points at a row that no longer exists.
        if let action = autoAdvanceAction, threadLeavesCurrentList(updated) {
            advanceForRemoval([thread.id], action: action)
        }

        // True optimistic ordering: publish the user-visible result before
        // SQLCipher or Gmail can delay it.
        applyOptimisticSidebarCountDelta(from: thread, to: updated)
        applyOptimisticThreadUpdate(updated)
        if !suppressThreadReload {
            scheduleThreadMutationReconciliation()
        }

        let persistence = enqueueThreadPersistence(from: thread, to: updated)
        let client = client(for: thread.accountId)
        let gmailThreadId = thread.gmailThreadId
        let isDemo = demoMode
        Task {
            switch await persistence.value {
            case .failure(let error):
                await MainActor.run {
                    self.lastError = "Couldn't save the local change: \(error.localizedDescription)"
                    // Roll the optimistic projection back from the database.
                    // The reconciliation waits for the serial write tail, so
                    // it cannot race a later user action.
                    self.scheduleThreadMutationReconciliation()
                }
                if !isDemo { await self.sync(accountId: thread.accountId) }
                return
            case .success:
                break
            }
            // Demo interactions are intentionally local. They should feel real
            // without attempting Gmail calls for the fictional account.
            guard !isDemo else { return }
            await self.applyRemoteThreadChange(
                remote, client: client, accountId: thread.accountId,
                gmailThreadId: gmailThreadId)
        }
        return updated
    }

    /// Push one optimistic edit to Gmail, or park it for replay.
    ///
    /// Offline (known, or discovered by this very call) the edit is folded
    /// into the thread's `PendingThreadOp` row: the local row already shows
    /// the result, and the replay before the next sync keeps Gmail's history
    /// from reverting it. A thread that already has a queued edit always
    /// queues (order matters: replay applies the folded change last).
    private func applyRemoteThreadChange(_ change: RemoteThreadChange,
                                         client: GmailClient,
                                         accountId: String,
                                         gmailThreadId: String) async {
        // An undo can have nothing to send (archive of a thread that had no
        // INBOX); Gmail rejects a modify with no labels.
        guard !change.isEmpty else { return }
        let pool = db
        let alreadyQueued = (try? await pool.read { db in
            try PendingThreadOp
                .filter(Column("accountId") == accountId
                        && Column("gmailThreadId") == gmailThreadId)
                .fetchCount(db) > 0
        }) ?? false
        if isOffline || alreadyQueued {
            await queueThreadChange(change, accountId: accountId, gmailThreadId: gmailThreadId)
            return
        }
        do {
            try await Self.perform(change, on: client, gmailThreadId: gmailThreadId)
            isOffline = false
        } catch {
            if OfflinePolicy.shouldDefer(error) {
                isOffline = true
                await queueThreadChange(change, accountId: accountId, gmailThreadId: gmailThreadId)
            } else if ThreadEditRetryPolicy.shouldRequeue(error) {
                // Quota or server error: Gmail is reachable (not offline)
                // but did not take the edit. Keep it for the replay ahead
                // of the next sync instead of reverting the thread.
                await queueThreadChange(change, accountId: accountId, gmailThreadId: gmailThreadId)
            } else {
                lastError = error.localizedDescription
                await rederiveThreadFromMessages(
                    accountId: accountId, gmailThreadId: gmailThreadId)
                await sync(accountId: accountId)
            }
        }
    }

    private static func perform(_ change: RemoteThreadChange, on client: GmailClient,
                                gmailThreadId: String) async throws {
        switch change {
        case .modify(let add, let remove):
            try await client.modifyThread(id: gmailThreadId, add: add, remove: remove)
        case .trash:
            try await client.trashThread(id: gmailThreadId)
        }
    }

    private func queueThreadChange(_ change: RemoteThreadChange,
                                   accountId: String, gmailThreadId: String) async {
        let pool = db
        do {
            try await pool.write { db in
                try PendingThreadOp.enqueue(db, accountId: accountId,
                                            gmailThreadId: gmailThreadId, change: change)
            }
        } catch {
            lastError = "Couldn't queue the change for later: \(error.localizedDescription)"
        }
        await reloadPendingThreadOpCount()
    }

    func reloadPendingThreadOpCount() async {
        let pool = db
        pendingThreadOpCount = (try? await pool.read { db in
            try PendingThreadOp.fetchCount(db)
        }) ?? 0
    }

    private func rederiveThreadFromMessages(accountId: String, gmailThreadId: String) async {
        let threadId = "\(accountId):\(gmailThreadId)"
        _ = try? await db.write { db in
            try OptimisticThreadWrite.rederiveOrDelete(db, threadId: threadId, accountId: accountId)
        }
        scheduleThreadMutationReconciliation()
    }

    /// Replay queued thread edits, oldest first. Runs ahead of every sync so
    /// Gmail's history reflects the user's offline work before it is read
    /// back. Stops at the first connectivity failure (still offline); drops
    /// rows Gmail rejects outright (a thread deleted meanwhile is a 404).
    /// A quota or server error keeps the row for the next pass, until the
    /// row passes `ThreadEditRetryPolicy.maxQueuedAge`. A failure that
    /// belongs to one account (reauthorization, quota) skips that account
    /// only; rows of a removed account are deleted (see `ThreadOpReplay`).
    func flushPendingThreadOps() async {
        guard !demoMode, !isShuttingDown, !pendingOpsFlushInFlight else { return }
        pendingOpsFlushInFlight = true
        defer { pendingOpsFlushInFlight = false }
        let pool = db
        let rows = (try? await pool.read { db in
            try PendingThreadOp.order(Column("createdAt")).fetchAll(db)
        }) ?? []
        guard !rows.isEmpty else {
            if pendingThreadOpCount != 0 { pendingThreadOpCount = 0 }
            return
        }
        var pass = ThreadOpReplay.Pass()
        replay: for row in rows {
            guard !isShuttingDown else { break }
            guard isKnownAccount(row.accountId) else {
                // The account was removed: no token, no thread rows. The
                // row can never be sent and would stay at the head of the
                // queue for ever.
                _ = try? await pool.write { db in
                    try PendingThreadOp.deleteIfAccountMissing(db, row: row)
                }
                continue
            }
            guard !pass.skips(row.accountId) else { continue }
            guard let change = row.change, !change.isEmpty else {
                await rederiveThreadFromMessages(
                    accountId: row.accountId, gmailThreadId: row.gmailThreadId)
                _ = try? await pool.write { db in try PendingThreadOp.deleteOne(db, key: row.id) }
                continue
            }
            let gmail = client(for: row.accountId)
            var shouldDelete = false
            var shouldRederive = false
            do {
                try await Self.perform(change, on: gmail, gmailThreadId: row.gmailThreadId)
                isOffline = false
                shouldDelete = true
            } catch {
                switch ThreadOpReplay.replayDisposition(
                    error: error, accountIsKnown: isKnownAccount(row.accountId),
                    createdAt: row.createdAt) {
                case .stopPass:
                    isOffline = true
                    break replay
                case .skipAccount(let reauthorize):
                    // The other accounts' rows still replay in this pass.
                    if reauthorize { requireReauthorization(for: row.accountId) }
                    pass.skip(row.accountId)
                    continue
                case .keepRow:
                    // Gmail is busy, not gone: the row stays queued.
                    pass.recordServerError(row.accountId)
                    continue
                case .dropRow(let revert, let report):
                    // Gone or rejected: the next sync shows Gmail's truth.
                    if report {
                        lastError = "Couldn't sync an offline change: \(error.localizedDescription)"
                    }
                    shouldDelete = true
                    shouldRederive = revert
                }
            }
            // Delete only if the row is still the one we replayed: a user edit
            // made during the flush folds into it (enqueue sees the row and
            // queues rather than calling Gmail), and an unconditional delete
            // would drop that edit on the floor. A row that did change stays
            // and replays next time — label edits and trash are idempotent, so
            // re-sending the already-sent part is harmless.
            if shouldDelete {
                let deleted = (try? await pool.write { db -> Bool in
                    let current = try PendingThreadOp.filter(Column("id") == row.id).fetchOne(db)
                    guard current?.updatedAt == row.updatedAt else { return false }
                    return try PendingThreadOp.deleteOne(db, key: row.id)
                }) ?? false
                // A row that picked up a new edit mid-flush stays queued; do
                // not revert the thread under that edit.
                if deleted, shouldRederive {
                    await rederiveThreadFromMessages(
                        accountId: row.accountId, gmailThreadId: row.gmailThreadId)
                }
            }
        }
        await reloadPendingThreadOpCount()
    }

    /// Writes the optimistic result to the thread row only. Message rows are
    /// left alone: they change when Gmail's history reports the edit, and
    /// until then they are the revert source if Gmail rejects it.
    private func enqueueThreadPersistence(
        from original: MailThread, to updated: MailThread
    ) -> Task<Result<Void, Error>, Never> {
        let predecessor = threadMutationPersistenceTask
        let pool = db
        let task: Task<Result<Void, Error>, Never> = Task.detached {
            () -> Result<Void, Error> in
            _ = await predecessor?.value
            do {
                try await pool.write { db in
                    try OptimisticThreadWrite.updateChangedColumns(db, from: original, to: updated)
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        threadMutationPersistenceTask = task
        return task
    }

    private func scheduleThreadMutationReconciliation() {
        guard !isShuttingDown else { return }
        threadMutationReconcileTask?.cancel()
        threadMutationReconcileTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 140_000_000)
            } catch {
                return
            }
            guard let self, !self.isShuttingDown else { return }
            let persistence = self.threadMutationPersistenceTask
            _ = await persistence?.value
            guard !Task.isCancelled, !self.isShuttingDown else { return }
            self.reloadThreads()
        }
    }

    private func applyOptimisticSidebarCountDelta(
        from old: MailThread, to updated: MailThread
    ) {
        if let activeAccountId, old.accountId != activeAccountId { return }
        let now = Date()
        let hide = inboxBadgeHideCategories
        let before = SidebarCounts.memberships(of: old, now: now, hideCategories: hide)
        let after = SidebarCounts.memberships(of: updated, now: now, hideCategories: hide)
        for key in before.subtracting(after) {
            unreadCounts[key] = max(0, (unreadCounts[key] ?? 0) - 1)
        }
        for key in after.subtracting(before) {
            unreadCounts[key] = (unreadCounts[key] ?? 0) + 1
        }
    }

    /// Apply `local`/`remote` to many threads with a single list reload.
    ///
    /// Two or more rows take the bulk path: one optimistic pass over the
    /// in-memory list, one write transaction for every thread row (instead of
    /// one chained transaction each), then the usual per-thread Gmail calls
    /// (`threads.modify` / `threads.trash`) run a few at a time per account.
    /// Per-thread calls stay on purpose: `threads.modify` also covers messages
    /// not synced yet, which an id-based `messages.batchModify` would miss.
    ///
    /// Returns the post-action copies, in `targets` order (the undo base).
    @discardableResult
    func mutateThreads(_ targets: [MailThread],
                       autoAdvanceAction: String? = nil,
                       remote: RemoteThreadChange,
                       local: (inout MailThread) -> Void) -> [MailThread] {
        guard !isShuttingDown, !targets.isEmpty else { return targets }
        if let action = autoAdvanceAction {
            let leaving = Set(targets.compactMap { thread -> String? in
                var updated = thread
                local(&updated)
                return threadLeavesCurrentList(updated) ? thread.id : nil
            })
            advanceForRemoval(
                leaving, action: action,
                extraMeta: "bulk=\(targets.count)")
        }
        guard targets.count > 1 else {
            suppressThreadReload = true
            let updated = mutateThread(targets[0], remote: remote, local: local)
            suppressThreadReload = false
            scheduleThreadMutationReconciliation()
            return [updated]
        }

        // Same optimistic order as `mutateThread`, per row, before any
        // SQLCipher or Gmail work can delay what the user sees.
        var edits: [(original: MailThread, updated: MailThread)] = []
        edits.reserveCapacity(targets.count)
        for thread in targets {
            var copy = thread
            local(&copy)
            applyOptimisticSidebarCountDelta(from: thread, to: copy)
            applyOptimisticThreadUpdate(copy)
            edits.append((thread, copy))
        }
        scheduleThreadMutationReconciliation()

        let persistence = enqueueBulkThreadPersistence(edits)
        let isDemo = demoMode
        var accountIds: [String] = []
        for thread in targets where !accountIds.contains(thread.accountId) {
            accountIds.append(thread.accountId)
        }
        // Bulk remote runs are chained: the calls inside one run are
        // bounded, so without the chain a quick bulk undo could reach Gmail
        // before the tail of the bulk action it undoes. Single-thread
        // edits stay independent tasks, as before.
        let predecessor = bulkRemoteTail
        bulkRemoteTail = Task {
            _ = await predecessor?.value
            if self.isShuttingDown { return }
            switch await persistence.value {
            case .failure(let error):
                // One transaction: every row rolled back together, so every
                // thread takes the failure handling `mutateThread` gives one.
                await MainActor.run {
                    self.lastError = "Couldn't save the local change: \(error.localizedDescription)"
                    self.scheduleThreadMutationReconciliation()
                }
                if !isDemo {
                    for accountId in accountIds { await self.sync(accountId: accountId) }
                }
                return
            case .success:
                break
            }
            guard !isDemo else { return }
            await self.applyRemoteBulkThreadChange(remote, threads: targets)
        }
        return edits.map(\.updated)
    }

    /// Undo one bulk action. `acted` are the post-action copies; threads
    /// that had no INBOX before the action do not get it from the undo.
    private func undoThreads(_ action: ThreadUndo.Action,
                             acted: [MailThread], originals: [MailThread]) {
        for group in ThreadUndo.undoGroups(acted: acted, originals: originals) {
            let wasInInbox = group.wasInInbox
            mutateThreads(group.threads,
                          remote: ThreadUndo.undoRemote(action, wasInInbox: wasInInbox),
                          local: { ThreadUndo.restore(action, wasInInbox: wasInInbox, &$0) })
        }
    }

    /// Bulk counterpart of `enqueueThreadPersistence`: every thread row in
    /// one write transaction, still chained behind the serial write tail so
    /// a later single-row edit cannot land before it.
    private func enqueueBulkThreadPersistence(
        _ edits: [(original: MailThread, updated: MailThread)]
    ) -> Task<Result<Void, Error>, Never> {
        let predecessor = threadMutationPersistenceTask
        let pool = db
        let task: Task<Result<Void, Error>, Never> = Task.detached {
            () -> Result<Void, Error> in
            _ = await predecessor?.value
            do {
                try await pool.write { db in
                    for edit in edits {
                        try OptimisticThreadWrite.updateChangedColumns(
                            db, from: edit.original, to: edit.updated)
                    }
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        threadMutationPersistenceTask = task
        return task
    }

    /// Gmail calls in flight at once per account for one bulk edit. The
    /// client's quota bucket already paces spend; the cap keeps a 500-row
    /// select-all from opening 500 requests while still overlapping round
    /// trips (the old path launched one unbounded task per thread).
    nonisolated static let bulkRemoteMaxInFlight = 4

    /// Push one bulk edit to Gmail through the per-thread path, bounded per
    /// account. Each thread keeps its own offline queueing, queued-edit
    /// folding, rollback, banner, and resync in `applyRemoteThreadChange`.
    private func applyRemoteBulkThreadChange(_ change: RemoteThreadChange,
                                             threads: [MailThread]) async {
        await BoundedLanes.run(threads, maxInFlight: Self.bulkRemoteMaxInFlight,
                               lane: { $0.accountId }) { thread in
            await self.applyRemoteBulkThreadMember(change, thread: thread)
        }
    }

    private func applyRemoteBulkThreadMember(_ change: RemoteThreadChange,
                                             thread: MailThread) async {
        guard !isShuttingDown else { return }
        await applyRemoteThreadChange(
            change, client: client(for: thread.accountId),
            accountId: thread.accountId, gmailThreadId: thread.gmailThreadId)
    }

    /// Re-pin threads under an active unread/read filter so a previously
    /// opened (now-read) conversation reappears in `is:unread`.
    ///
    /// Must run **before** `mutateThread(s)` on undo: `reloadThreads` snapshots
    /// `readStateKeepIds` synchronously at call time, so a pin after the
    /// mutation never reaches the reload query.
    private func pinReadStateKeep(_ ids: [String]) {
        guard readStateFilterActive else { return }
        for id in ids { readStateKeepIds.insert(id) }
    }

    /// Pin just-unstarred threads so category-hide / Starred / is:starred lists
    /// do not yank the row mid-triage. Same call-before-mutate rule as read.
    /// Under thread-long policy, only selected / multi-checked ids retain a
    /// pin (unstar on a non-focused row leaves immediately — no orphan pin
    /// waiting for an unrelated selection change).
    private func pinStarStateKeep(_ ids: [String]) {
        guard starStateFilterActive else { return }
        for id in ids { starStateKeepIds.insert(id) }
        if currentStarStickinessPolicy() == .thread {
            applyThreadLongStarPinDrops(selectionIntent: nil)
        }
    }

    private func restoreSelectionFocus(_ id: String?) {
        guard let id else { return }
        selectThread(id, intent: .restoreFocus)
    }

    /// Apply a local mutation to the in-memory list without waiting for the
    /// async DB reload. Drops the row when it no longer belongs in the current
    /// view (archive from inbox, trash, etc.) so selection advance works.
    ///
    /// Leave-list always wins over read/star keepIds: stickiness only keeps
    /// mark-read / unstar rows under filters, and must not block trash/archive
    /// auto-advance (otherwise the row sticks until async reload, advance
    /// sees it still present, and selection ends up empty).
    private func applyOptimisticThreadUpdate(_ updated: MailThread) {
        let plan = ThreadListOptimistic.plan(leavesCurrentList: threadLeavesCurrentList(updated))
        guard let idx = threads.firstIndex(where: { $0.id == updated.id }) else {
            if plan.effect == .updateInPlace {
                // Undo restore path: only insert when this list can own the
                // row. Wrong-account filter or a committed search would flash
                // the row until ~140ms reconciliation reloads the right list.
                let hasSearch = !committedSearch
                    .trimmingCharacters(in: .whitespaces).isEmpty
                guard ThreadListOptimistic.shouldReinsertAbsent(
                    threadAccountId: updated.accountId,
                    activeAccountId: activeAccountId,
                    committedSearchActive: hasSearch) else { return }
                let inbound = Self.usesInboundSort(for: selectedView)
                let insertion = ThreadListOptimistic.insertionIndex(
                    for: updated, in: threads, inboundSort: inbound)
                threads.insert(updated, at: insertion)
                listWindowLimit = max(listWindowLimit, threads.count)
            }
            return
        }
        switch plan.effect {
        case .remove:
            threads.remove(at: idx)
            if plan.sideEffects.dropKeepId {
                readStateKeepIds.remove(updated.id)
                starStateKeepIds.remove(updated.id)
            }
            if plan.sideEffects.dropChecked { checkedThreadIds.remove(updated.id) }
        case .updateInPlace:
            threads[idx] = updated
        }
    }

    /// Move list focus and mounted detail independently before their rows are
    /// removed. Rapid browsing intentionally lets those ids differ.
    private func advanceForRemoval(_ removing: Set<String>, action: String,
                                   extraMeta: String = "") {
        guard !removing.isEmpty else { return }
        let destinations = SelectionAdvance.destinations(
            in: selectionOrder,
            removing: removing,
            selected: selectedThreadId,
            opened: openedThreadId)
        guard destinations.selectedWasRemoved || destinations.openedWasRemoved
        else { return }

        let interval = PerfMetrics.begin(
            .actionAdvance,
            meta: ["action=\(action)", extraMeta]
                .filter { !$0.isEmpty }.joined(separator: " "))
        // Mount the replacement first so optimistic removal cannot expose the
        // empty-state view, but leave unrelated mounted content untouched.
        if destinations.openedWasRemoved {
            openDetail(destinations.openedId)
        }
        if destinations.selectedWasRemoved {
            setSelectionFocus(destinations.selectedId, intent: .autoAdvance)
        }
        interval.end(extraMeta: destinations.openedId == nil ? "empty" : "neighbor")
    }

    /// Unstar in the inbox Priority section: the row stays in the list, so
    /// leave-list advance never fires. Before mutate re-partitions the row
    /// into date groups, jump selection to the next Priority neighbor
    /// (down, then up). When the section empties, destinations are nil —
    /// deliberately do nothing; selection stays on the still-listed row.
    private func advanceForPriorityUnstar(_ targets: [MailThread]) {
        guard selectedView == .inbox, !prioritySectionIds.isEmpty else { return }
        let modeRaw = UserDefaults.standard.string(forKey: "priorityMode")
        let mode = PrioritySplit.Mode(rawValue: modeRaw ?? "") ?? .starred
        guard mode != .off else { return }
        // Match ThreadListView @AppStorage: key absent means true; bool(forKey:)
        // alone would default to false when the key is missing.
        let vipAlwaysPins: Bool = {
            if UserDefaults.standard.object(forKey: "vipAlwaysPins") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "vipAlwaysPins")
        }()
        // Match ThreadListView @AppStorage default 7; integer(forKey:) is 0 when absent.
        let priorityWindowDays: Int = {
            if UserDefaults.standard.object(forKey: "priorityWindowDays") == nil {
                return 7
            }
            return UserDefaults.standard.integer(forKey: "priorityWindowDays")
        }()
        let newerThan = PrioritySplit.cutoff(days: priorityWindowDays)

        let leaving = PrioritySectionAdvance.idsLeavingSection(
            targets: targets,
            sectionIds: Set(prioritySectionIds),
            mode: mode,
            vipThreadIds: vipThreadIds,
            vipAlwaysPins: vipAlwaysPins,
            newerThan: newerThan)
        guard !leaving.isEmpty else { return }

        let destinations = PrioritySectionAdvance.destinations(
            sectionOrder: prioritySectionIds,
            leaving: leaving,
            selected: selectedThreadId,
            opened: openedThreadId)
        // Section emptied (or focus not in section) → leave selection alone.
        guard destinations.selectedWasRemoved || destinations.openedWasRemoved
        else { return }

        let interval = PerfMetrics.begin(
            .actionAdvance, meta: "action=unstar-priority")
        // openDetail first so the pane never points at nothing mid-handoff.
        if destinations.openedWasRemoved, let next = destinations.openedId {
            openDetail(next)
        }
        if destinations.selectedWasRemoved, let next = destinations.selectedId {
            // setSelectionFocus writes selectedThreadId whose setter runs
            // applyThreadLongStarPinDrops with the .autoAdvance intent — under
            // .thread stickiness policy that drops the just-added pin for the
            // no-longer-selected row so hidden-category mail leaves the Primary
            // list; that cascade is correct and intended.
            setSelectionFocus(next, intent: .autoAdvance)
        }
        interval.end(
            extraMeta: destinations.selectedId == nil
                && destinations.openedId == nil ? "empty" : "neighbor")
    }

    /// Best-effort visibility check for the common leave-list mutations.
    /// Async reload is the source of truth for edge-case chip combinations.
    private func threadLeavesCurrentList(_ t: MailThread) -> Bool {
        // A committed `/` search replaces the selected view's filters. Use the
        // same mailbox scope as `reloadThreads` so optimistic trash/spam stay
        // gone (and archive from search keeps the row — search includes archive).
        let search = committedSearch.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty {
            let parsed = SearchQuery.parse(search)
            // is:starred stickiness: a just-unstarred pin stays until search clears.
            if parsed.starred, !t.isStarred, !starStateKeepIds.contains(t.id) {
                return true
            }
            return !parsed.includesLocation(inTrash: t.inTrash, inSpam: t.inSpam)
        }
        if t.inTrash {
            if case .trash = selectedView { return false }
            return true
        }
        switch selectedView {
        case .inbox, .account:
            if ThreadListOptimistic.leavesInboxList(
                inInbox: t.inInbox,
                inSpam: t.inSpam,
                snoozeUntil: t.snoozeUntil,
                showArchived: chips.showArchived,
                showSent: chips.showSent,
                labelIds: t.labelIds) {
                return true
            }
            // Category-hide pin-through: unstarred hidden-category mail leaves
            // once the sticky keep is gone (leave-thread drop or never pinned).
            return StarStickiness.leavesDueToCategoryHide(
                hide: chips.category.hide,
                inPromotions: t.inPromotions,
                inSocial: t.inSocial,
                labelIds: t.labelIds,
                isStarred: t.isStarred,
                isKept: starStateKeepIds.contains(t.id))
        case .promotions:
            // Gmail-aligned: inbox promotions only, never spam/trash.
            return t.inSpam || !t.inInbox || !t.inPromotions
        case .social:
            return t.inSpam || !t.inInbox || !t.inSocial
        case .starred:
            // Sticky keep after unstar so triage can continue in Starred.
            return !t.isStarred && !starStateKeepIds.contains(t.id)
        case .snoozed:
            guard let until = t.snoozeUntil else { return true }
            return until <= Date()
        case .trash:
            return !t.inTrash
        case .allMail:
            return false
        default:
            return false
        }
    }

    private func offerUndo(_ label: String, undo: @escaping () -> Void) {
        undoAction = UndoAction(label: label, undo: undo)
        undoTimer?.invalidate()
        undoTimer = Timer.scheduledTimer(withTimeInterval: UndoToast.displayDuration,
                                         repeats: false) { [weak self] _ in
            Task { @MainActor in self?.clearOrRestoreUndoToast() }
        }
    }

    /// Drop a short triage toast, or put "Sending…" back if undo-send is
    /// still live (archive-after-send must not orphan the cancel-send chord).
    private func clearOrRestoreUndoToast() {
        undoTimer = nil
        if UndoToast.shouldRestoreSendUndo(pendingSend: pendingSend != nil) {
            undoAction = UndoAction(label: "Sending…") { [weak self] in
                self?.cancelPendingSend()
            }
        } else {
            undoAction = nil
        }
    }

    /// Display order used for neighbor / multi-select range (list layout when
    /// known, otherwise current `threads` order).
    var selectionOrder: [String] {
        displayOrder.isEmpty ? threads.map(\.id) : displayOrder
    }

    /// Threads currently multi-selected, in list order.
    private var checkedThreadsInOrder: [MailThread] {
        let byId = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        let checked = checkedThreadIds
        return selectionOrder.compactMap { id in
            guard checked.contains(id) else { return nil }
            return byId[id]
        }
    }

    func archive(_ thread: MailThread) {
        let priorFocus = selectedThreadId
        // Archive always marks read: selection advance cancels the reading-pane
        // dwell timer, and Gmail's own archive treats the conversation as seen.
        let wasInInbox = thread.inInbox
        let acted = mutateThread(thread, autoAdvanceAction: "archive",
                                 remote: ThreadUndo.remote(.archive)) {
            ThreadUndo.apply(.archive, &$0)
        }
        offerUndo("Archived") { [weak self] in
            guard let self else { return }
            self.pinReadStateKeep([thread.id])
            // Undo restores inbox only — stay read (matches Gmail undo-archive).
            self.mutateThread(
                acted, remote: ThreadUndo.undoRemote(.archive, wasInInbox: wasInInbox)
            ) {
                ThreadUndo.restore(.archive, wasInInbox: wasInInbox, &$0)
            }
            self.restoreSelectionFocus(priorFocus)
            self.undoAction = nil
        }
    }

    /// Bulk archive for multi-select. Advances focus once past the removed block.
    func archiveChecked() {
        let targets = checkedThreadsInOrder
        guard !targets.isEmpty else { return }
        let focus = selectedThreadId
        // Same as single archive: drop UNREAD so a fast multi-select `e`
        // does not leave archived mail unread (dwell is cancelled by advance).
        let acted = mutateThreads(targets, autoAdvanceAction: "archive",
                                  remote: ThreadUndo.remote(.archive), local: {
            ThreadUndo.apply(.archive, &$0)
        })
        clearCheckedThreads()
        let n = targets.count
        let ids = targets.map(\.id)
        offerUndo(n == 1 ? "Archived" : "Archived \(n) conversations") { [weak self] in
            guard let self else { return }
            self.pinReadStateKeep(ids)
            self.undoThreads(.archive, acted: acted, originals: targets)
            self.restoreSelectionFocus(focus)
            self.undoAction = nil
        }
    }

    /// Gmail moves the whole thread to Spam; it leaves the inbox locally
    /// right away and drops out of Promotions/Social (those views exclude
    /// `inSpam`). Matches blocklist's labelIds/denorm update so optimistic
    /// UI and the next sync agree.
    func markSpam(_ thread: MailThread) {
        let priorFocus = selectedThreadId
        let wasInInbox = thread.inInbox
        let acted = mutateThread(thread, autoAdvanceAction: "spam",
                                 remote: ThreadUndo.remote(.spam)) {
            ThreadUndo.apply(.spam, &$0)
        }
        offerUndo("Marked as spam") { [weak self] in
            guard let self else { return }
            self.pinReadStateKeep([thread.id])
            self.mutateThread(
                acted, remote: ThreadUndo.undoRemote(.spam, wasInInbox: wasInInbox)
            ) {
                ThreadUndo.restore(.spam, wasInInbox: wasInInbox, &$0)
            }
            self.restoreSelectionFocus(priorFocus)
            self.undoAction = nil
        }
    }

    /// Inverse of `markSpam`: remove SPAM, restore INBOX. Used from the
    /// overflow menu when the thread is already in Spam (and as spam-undo).
    func markNotSpam(_ thread: MailThread) {
        let priorFocus = selectedThreadId
        let wasInInbox = thread.inInbox
        let acted = mutateThread(thread, autoAdvanceAction: "not-spam",
                                 remote: ThreadUndo.remote(.notSpam)) {
            ThreadUndo.apply(.notSpam, &$0)
        }
        offerUndo("Marked as not spam") { [weak self] in
            guard let self else { return }
            self.pinReadStateKeep([thread.id])
            self.mutateThread(
                acted, remote: ThreadUndo.undoRemote(.notSpam, wasInInbox: wasInInbox)
            ) {
                ThreadUndo.restore(.notSpam, wasInInbox: wasInInbox, &$0)
            }
            self.restoreSelectionFocus(priorFocus)
            self.undoAction = nil
        }
    }

    /// Bulk spam: if any checked row is not spam, mark all spam; else not-spam
    /// all (mirrors star/read bulk majority and the single-thread `!` toggle).
    func markSpamChecked() {
        let targets = checkedThreadsInOrder
        guard !targets.isEmpty else { return }
        let focus = selectedThreadId
        let markAsSpam = targets.contains { !$0.inSpam }
        let action: ThreadUndo.Action = markAsSpam ? .spam : .notSpam
        let acted = mutateThreads(targets, autoAdvanceAction: markAsSpam ? "spam" : "not-spam",
                                  remote: ThreadUndo.remote(action), local: {
            ThreadUndo.apply(action, &$0)
        })
        clearCheckedThreads()
        let n = targets.count
        let ids = targets.map(\.id)
        let undoLabel = markAsSpam
            ? (n == 1 ? "Marked as spam" : "Marked \(n) as spam")
            : (n == 1 ? "Marked as not spam" : "Marked \(n) as not spam")
        offerUndo(undoLabel) { [weak self] in
            guard let self else { return }
            self.pinReadStateKeep(ids)
            self.undoThreads(action, acted: acted, originals: targets)
            self.restoreSelectionFocus(focus)
            self.undoAction = nil
        }
    }

    func trash(_ thread: MailThread) {
        // Gmail-style auto-advance: when the selected thread is trashed, land
        // on the next conversation down (or the one above if it was last)
        // instead of leaving nothing selected. Computed before the mutation
        // removes the row from `threads`.
        let priorFocus = selectedThreadId
        // Keep labelIds + denorm flags coherent (same pattern as markSpam) so
        // search filters on inTrash and any labelIds-based UI agree.
        let wasInInbox = thread.inInbox
        let acted = mutateThread(thread, autoAdvanceAction: "trash",
                                 remote: ThreadUndo.remote(.trash)) {
            ThreadUndo.apply(.trash, &$0)
        }
        offerUndo("Moved to Trash") { [weak self] in
            guard let self else { return }
            // Pin before mutate so reloadThreads snapshots keepIds (opened-
            // under-is:unread rows were auto-marked read and dropped keepIds
            // on trash).
            self.pinReadStateKeep([thread.id])
            self.mutateThread(
                acted, remote: ThreadUndo.undoRemote(.trash, wasInInbox: wasInInbox)
            ) {
                ThreadUndo.restore(.trash, wasInInbox: wasInInbox, &$0)
            }
            self.restoreSelectionFocus(priorFocus)
            self.undoAction = nil
        }
    }

    /// Bulk trash for multi-select.
    func trashChecked() {
        let targets = checkedThreadsInOrder
        guard !targets.isEmpty else { return }
        let focus = selectedThreadId
        let acted = mutateThreads(targets, autoAdvanceAction: "trash",
                                  remote: ThreadUndo.remote(.trash), local: {
            ThreadUndo.apply(.trash, &$0)
        })
        clearCheckedThreads()
        let n = targets.count
        let ids = targets.map(\.id)
        offerUndo(n == 1 ? "Moved to Trash" : "Moved \(n) to Trash") { [weak self] in
            guard let self else { return }
            self.pinReadStateKeep(ids)
            self.undoThreads(.trash, acted: acted, originals: targets)
            self.restoreSelectionFocus(focus)
            self.undoAction = nil
        }
    }

    func toggleStar(_ thread: MailThread) {
        let starring = !thread.isStarred
        // Pin before mutate so optimistic leave-list and reload both see the id.
        if !starring {
            pinStarStateKeep([thread.id])
            // Before mutate re-partitions the Priority row into date groups.
            // setSelectionFocus's .autoAdvance intent drops the just-added pin
            // under .thread stickiness for the left row (intended cascade).
            advanceForPriorityUnstar([thread])
        } else {
            captureStarNavAnchor(starredIds: [thread.id])
        }
        mutateThread(thread, remote: .modify(add: starring ? ["STARRED"] : [],
                                             remove: starring ? [] : ["STARRED"])) {
            $0.isStarred = starring
        }
    }

    /// Bulk star: if any checked thread is unstarred, star all; else unstar all.
    func toggleStarChecked() {
        let targets = checkedThreadsInOrder
        guard !targets.isEmpty else { return }
        let starring = targets.contains { !$0.isStarred }
        if !starring {
            pinStarStateKeep(targets.map(\.id))
            advanceForPriorityUnstar(targets)
        } else {
            captureStarNavAnchor(starredIds: Set(targets.map(\.id)))
        }
        mutateThreads(targets, remote: .modify(add: starring ? ["STARRED"] : [],
                                               remove: starring ? [] : ["STARRED"]),
                      local: { $0.isStarred = starring })
    }

    /// Remember pre-star Down/Up neighbors so the next ±1 move stays in the
    /// original list position after the row jumps into Priority. Also sets a
    /// one-shot viewport hold so the list does not scroll up to Priority with
    /// the selected row. Only when Priority is active, the focused row is
    /// among the starred set, and that row is not already in the Priority
    /// section (no re-partition).
    private func captureStarNavAnchor(starredIds: Set<String>) {
        guard selectedView == .inbox else { return }
        let modeRaw = UserDefaults.standard.string(forKey: "priorityMode")
        let mode = PrioritySplit.Mode(rawValue: modeRaw ?? "") ?? .starred
        guard mode != .off else { return }
        guard !displayOrder.isEmpty else { return }
        guard let focusId = selectedThreadId, starredIds.contains(focusId)
        else { return }
        // Already Priority-qualified → starring does not re-partition it.
        guard !prioritySectionIds.contains(focusId) else { return }
        // Starring an old thread outside the Priority window does not hoist
        // it, so a scroll/nav hold would freeze the viewport for nothing.
        if let focused = threads.first(where: { $0.id == focusId }) {
            let vipAlwaysPins: Bool = {
                if UserDefaults.standard.object(forKey: "vipAlwaysPins") == nil {
                    return true
                }
                return UserDefaults.standard.bool(forKey: "vipAlwaysPins")
            }()
            let priorityWindowDays: Int = {
                if UserDefaults.standard.object(forKey: "priorityWindowDays") == nil {
                    return 7
                }
                return UserDefaults.standard.integer(forKey: "priorityWindowDays")
            }()
            let priorityMaxCount: Int = {
                if UserDefaults.standard.object(forKey: "priorityMaxCount") == nil {
                    return 10
                }
                return UserDefaults.standard.integer(forKey: "priorityMaxCount")
            }()
            var starred = focused
            starred.isStarred = true
            if !PrioritySplit.qualifies(
                starred, mode: mode,
                vipThreadIds: vipThreadIds,
                vipAlwaysPins: vipAlwaysPins,
                hiddenCategories: effectiveCategoryHide,
                newerThan: PrioritySplit.cutoff(days: priorityWindowDays)
            ) {
                return
            }
            // Cap full and focused thread would not displace into Priority
            // (not VIP-exempt, older than oldest current Priority row): starring
            // won't visibly hoist it, so skip the scroll/nav hold.
            if let maxCount = PrioritySplit.cap(priorityMaxCount),
               prioritySectionIds.count >= maxCount {
                let isVIPExempt = vipAlwaysPins && vipThreadIds.contains(focusId)
                if !isVIPExempt {
                    var oldestPriorityDate: Date?
                    var unresolved = false
                    for id in prioritySectionIds {
                        guard let t = threads.first(where: { $0.id == id }) else {
                            unresolved = true
                            break
                        }
                        if oldestPriorityDate == nil || t.lastDate < oldestPriorityDate! {
                            oldestPriorityDate = t.lastDate
                        }
                    }
                    if !unresolved,
                       let oldest = oldestPriorityDate,
                       focused.lastDate < oldest {
                        return
                    }
                }
            }
        }
        guard let anchor = StarNavAnchor.anchor(
            displayOrder: displayOrder,
            focusId: focusId,
            starredIds: starredIds) else { return }
        starNavAnchor = anchor
        // Neighbor that is *not* moving with the star re-partition.
        starScrollHoldId = StarNavAnchor.holdId(from: anchor)
    }

    func setRead(_ thread: MailThread, read: Bool) {
        if readStateFilterActive { readStateKeepIds.insert(thread.id) }
        mutateThread(thread, remote: .modify(add: read ? [] : ["UNREAD"],
                                             remove: read ? ["UNREAD"] : [])) {
            $0.isUnread = !read
        }
    }

    /// Gmail Shift+I / Shift+U with state-aware Shift+I (already-read → unread).
    /// Targets the checked set when multi-select is active, else the focused row.
    func applyGmailMarkReadChord(_ chord: GmailMarkReadKeys.Chord) {
        let targets: [MailThread]
        if !checkedThreadIds.isEmpty {
            targets = checkedThreadsInOrder
        } else if let t = selectedThread {
            targets = [t]
        } else {
            return
        }
        let anyUnread = targets.contains { $0.isUnread }
        let read = GmailMarkReadKeys.desiredRead(chord: chord, anyUnread: anyUnread)
        guard targets.count > 1 else {
            setRead(targets[0], read: read)
            return
        }
        // Same keep-pin as `setRead`, then one bulk mutation so a
        // multi-select mark-read batches like archive and star do.
        pinReadStateKeep(targets.map(\.id))
        mutateThreads(targets, remote: .modify(add: read ? [] : ["UNREAD"],
                                               remove: read ? ["UNREAD"] : [])) {
            $0.isUnread = !read
        }
    }

    /// Bulk read toggle: if any checked is unread, mark all read; else unread.
    func toggleReadChecked() {
        guard !checkedThreadIds.isEmpty else { return }
        // Same state rule as Shift+I on a multi-select.
        applyGmailMarkReadChord(.shiftI)
    }

    /// Drop the snooze overlay immediately. Archive/trash are single-key and
    /// hand off in the same update; any residual presentation animation would
    /// still defer the reading-pane swap after a pick, so clear without
    /// animation even though the picker is no longer a modal sheet.
    func dismissSnoozePicker() {
        guard snoozingThread != nil || snoozingChecked else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { snoozingThread = nil; snoozingChecked = false }
    }

    /// Snooze mirrors what Gmail's own snooze looks like over the API: the
    /// thread loses INBOX while sleeping and gets it back when the date
    /// passes (or on unsnooze), so other Gmail clients agree with us.
    /// `snoozeUntil` itself stays local — the API has no snooze field —
    /// which also means threads snoozed *in* Gmail arrive here as archived
    /// and reappear on sync when Gmail wakes them.
    func snooze(_ thread: MailThread, until date: Date?) {
        guard let date else {  // unsnooze: back to the inbox now
            // Only close the picker when it was opened for *this* thread —
            // fireDueSnoozes / Undo must not yank a picker for another row.
            if snoozingThread?.id == thread.id {
                dismissSnoozePicker()
            }
            mutateThread(thread, remote: .modify(add: ["INBOX"])) {
                $0.snoozeUntil = nil; $0.inInbox = true
            }
            return
        }
        // Tear the picker down *before* the optimistic mutation so auto-advance
        // publishes into a visible window (same frame as archive/trash).
        dismissSnoozePicker()
        let action = ThreadUndo.Action.snooze(until: date)
        let wasInInbox = thread.inInbox
        let acted = mutateThread(thread, autoAdvanceAction: "snooze",
                                 remote: ThreadUndo.remote(action)) {
            ThreadUndo.apply(action, &$0)
        }
        // Reuse the shared formatter path — allocating DateFormatter on the
        // triage hot path is needlessly expensive on the main thread.
        offerUndo(SnoozeDateParser.undoLabel(until: date)) { [weak self] in
            guard let self else { return }
            // Same picker rule as unsnooze: close it only for this thread.
            if self.snoozingThread?.id == thread.id {
                self.dismissSnoozePicker()
            }
            self.mutateThread(
                acted, remote: ThreadUndo.undoRemote(action, wasInInbox: wasInInbox)
            ) {
                ThreadUndo.restore(action, wasInInbox: wasInInbox, &$0)
            }
            self.undoAction = nil
        }
    }

    /// Bulk snooze: apply one picked date to every checked thread at once,
    /// mirroring archiveChecked/trashChecked. `perform(.snooze)` routes here
    /// instead of `snooze(_:until:)` whenever `checkedThreadIds` is
    /// non-empty — previously the sheet was always opened for just
    /// `selectedThread`, so multi-select `h`/`b` silently snoozed only the
    /// last-focused row.
    func snoozeChecked(until date: Date) {
        // Tear the picker down *before* the optimistic mutation — same
        // reason as the single-thread path above. Also before the empty
        // guard: checked ids can outlive their rows (filtered out of the
        // current list), and a picker left open on a no-op pick looks stuck.
        dismissSnoozePicker()
        let targets = checkedThreadsInOrder
        guard !targets.isEmpty else { return }
        let focus = selectedThreadId
        let action = ThreadUndo.Action.snooze(until: date)
        let acted = mutateThreads(targets, autoAdvanceAction: "snooze",
                                  remote: ThreadUndo.remote(action), local: {
            ThreadUndo.apply(action, &$0)
        })
        clearCheckedThreads()
        let n = targets.count
        let ids = targets.map(\.id)
        let label = n == 1
            ? SnoozeDateParser.undoLabel(until: date)
            : "Snoozed \(n) conversations until \(SnoozeDateParser.format(date))"
        offerUndo(label) { [weak self] in
            guard let self else { return }
            self.pinReadStateKeep(ids)
            self.undoThreads(action, acted: acted, originals: targets)
            self.restoreSelectionFocus(focus)
            self.undoAction = nil
        }
    }

    /// Wakes snoozed threads whose date has passed: clears the snooze and
    /// restores INBOX (locally and on Gmail). Runs on the sync tick.
    func fireDueSnoozes() async {
        let now = Date()
        let pool = db
        let due = (try? await pool.read { db in
            try MailThread
                .filter(Column("snoozeUntil") != nil && Column("snoozeUntil") <= now)
                .fetchAll(db)
        }) ?? []
        for thread in due { snooze(thread, until: nil) }
    }
}
