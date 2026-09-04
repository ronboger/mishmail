import Foundation
import SwiftUI
import AppKit
import GRDB

extension MailStore {
    // MARK: - Actions (optimistic local write, then remote, then resync on failure)


    func mutateThread(_ thread: MailThread,
                              autoAdvanceAction: String? = nil,
                              local: (inout MailThread) -> Void,
                              remote: @escaping (GmailClient, String) async throws -> Void) {
        guard !isShuttingDown else { return }
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

        let persistence = enqueueThreadPersistence(updated)
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
            do {
                try await remote(client, gmailThreadId)
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
                await self.sync(accountId: thread.accountId)
            }
        }
    }

    private func enqueueThreadPersistence(
        _ updated: MailThread
    ) -> Task<Result<Void, Error>, Never> {
        let predecessor = threadMutationPersistenceTask
        let pool = db
        let task: Task<Result<Void, Error>, Never> = Task.detached {
            () -> Result<Void, Error> in
            _ = await predecessor?.value
            do {
                try await pool.write { db in
                    try updated.save(db)
                    try ThreadLabels.rewrite(
                        db, threadId: updated.id, labelIds: updated.labelIds)
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
    /// Remote calls still fan out (one Task each) but the thread-list query
    /// runs once after all optimistic writes.
    func mutateThreads(_ targets: [MailThread],
                               autoAdvanceAction: String? = nil,
                               local: (inout MailThread) -> Void,
                               remote: @escaping (GmailClient, String) async throws -> Void) {
        guard !isShuttingDown, !targets.isEmpty else { return }
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
        suppressThreadReload = true
        for thread in targets {
            mutateThread(thread, local: local, remote: remote)
        }
        suppressThreadReload = false
        scheduleThreadMutationReconciliation()
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
        mutateThread(thread, autoAdvanceAction: "archive") {
            $0.inInbox = false
            $0.isUnread = false
        } remote: { client, id in
            try await client.modifyThread(id: id, remove: ["INBOX", "UNREAD"])
        }
        offerUndo("Archived") { [weak self] in
            guard let self else { return }
            self.pinReadStateKeep([thread.id])
            // Undo restores inbox only — stay read (matches Gmail undo-archive).
            // Local starts from the pre-archive snapshot, so re-assert isUnread.
            self.mutateThread(thread) {
                $0.inInbox = true
                $0.isUnread = false
            } remote: { client, id in
                try await client.modifyThread(id: id, add: ["INBOX"])
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
        mutateThreads(targets, autoAdvanceAction: "archive", local: {
            $0.inInbox = false
            $0.isUnread = false
        }, remote: { client, id in
            try await client.modifyThread(id: id, remove: ["INBOX", "UNREAD"])
        })
        clearCheckedThreads()
        let n = targets.count
        let ids = targets.map(\.id)
        offerUndo(n == 1 ? "Archived" : "Archived \(n) conversations") { [weak self] in
            guard let self else { return }
            self.pinReadStateKeep(ids)
            self.mutateThreads(targets, local: {
                $0.inInbox = true
                $0.isUnread = false
            }, remote: { client, id in
                try await client.modifyThread(id: id, add: ["INBOX"])
            })
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
        mutateThread(thread, autoAdvanceAction: "spam") { t in
            t.applyLabelMutation(add: ["SPAM"], remove: ["INBOX"])
        } remote: { client, id in
            try await client.modifyThread(id: id, add: ["SPAM"], remove: ["INBOX"])
        }
        offerUndo("Marked as spam") { [weak self] in
            guard let self else { return }
            self.pinReadStateKeep([thread.id])
            self.mutateThread(thread) { t in
                t.applyLabelMutation(add: ["INBOX"], remove: ["SPAM"])
            } remote: { client, id in
                try await client.modifyThread(id: id, add: ["INBOX"], remove: ["SPAM"])
            }
            self.restoreSelectionFocus(priorFocus)
            self.undoAction = nil
        }
    }

    /// Inverse of `markSpam`: remove SPAM, restore INBOX. Used from the
    /// overflow menu when the thread is already in Spam (and as spam-undo).
    func markNotSpam(_ thread: MailThread) {
        let priorFocus = selectedThreadId
        mutateThread(thread, autoAdvanceAction: "not-spam") { t in
            t.applyLabelMutation(add: ["INBOX"], remove: ["SPAM"])
        } remote: { client, id in
            try await client.modifyThread(id: id, add: ["INBOX"], remove: ["SPAM"])
        }
        offerUndo("Marked as not spam") { [weak self] in
            guard let self else { return }
            self.pinReadStateKeep([thread.id])
            self.mutateThread(thread) { t in
                t.applyLabelMutation(add: ["SPAM"], remove: ["INBOX"])
            } remote: { client, id in
                try await client.modifyThread(id: id, add: ["SPAM"], remove: ["INBOX"])
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
        if markAsSpam {
            mutateThreads(targets, autoAdvanceAction: "spam", local: { t in
                t.applyLabelMutation(add: ["SPAM"], remove: ["INBOX"])
            }, remote: { client, id in
                try await client.modifyThread(id: id, add: ["SPAM"], remove: ["INBOX"])
            })
        } else {
            mutateThreads(targets, autoAdvanceAction: "not-spam", local: { t in
                t.applyLabelMutation(add: ["INBOX"], remove: ["SPAM"])
            }, remote: { client, id in
                try await client.modifyThread(id: id, add: ["INBOX"], remove: ["SPAM"])
            })
        }
        clearCheckedThreads()
        let n = targets.count
        let ids = targets.map(\.id)
        let undoLabel = markAsSpam
            ? (n == 1 ? "Marked as spam" : "Marked \(n) as spam")
            : (n == 1 ? "Marked as not spam" : "Marked \(n) as not spam")
        offerUndo(undoLabel) { [weak self] in
            guard let self else { return }
            self.pinReadStateKeep(ids)
            if markAsSpam {
                self.mutateThreads(targets, local: { t in
                    t.applyLabelMutation(add: ["INBOX"], remove: ["SPAM"])
                }, remote: { client, id in
                    try await client.modifyThread(id: id, add: ["INBOX"], remove: ["SPAM"])
                })
            } else {
                self.mutateThreads(targets, local: { t in
                    t.applyLabelMutation(add: ["SPAM"], remove: ["INBOX"])
                }, remote: { client, id in
                    try await client.modifyThread(id: id, add: ["SPAM"], remove: ["INBOX"])
                })
            }
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
        mutateThread(thread, autoAdvanceAction: "trash") { t in
            t.applyLabelMutation(add: ["TRASH"], remove: ["INBOX"])
        } remote: { client, id in
            try await client.trashThread(id: id)
        }
        offerUndo("Moved to Trash") { [weak self] in
            guard let self else { return }
            // Pin before mutate so reloadThreads snapshots keepIds (opened-
            // under-is:unread rows were auto-marked read and dropped keepIds
            // on trash).
            self.pinReadStateKeep([thread.id])
            self.mutateThread(thread) { t in
                t.applyLabelMutation(add: ["INBOX"], remove: ["TRASH"])
            } remote: { client, id in
                try await client.modifyThread(id: id, add: ["INBOX"], remove: ["TRASH"])
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
        mutateThreads(targets, autoAdvanceAction: "trash", local: { t in
            t.applyLabelMutation(add: ["TRASH"], remove: ["INBOX"])
        }, remote: { client, id in
            try await client.trashThread(id: id)
        })
        clearCheckedThreads()
        let n = targets.count
        let ids = targets.map(\.id)
        offerUndo(n == 1 ? "Moved to Trash" : "Moved \(n) to Trash") { [weak self] in
            guard let self else { return }
            self.pinReadStateKeep(ids)
            self.mutateThreads(targets, local: { t in
                t.applyLabelMutation(add: ["INBOX"], remove: ["TRASH"])
            }, remote: { client, id in
                try await client.modifyThread(id: id, add: ["INBOX"], remove: ["TRASH"])
            })
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
        mutateThread(thread) { $0.isStarred = starring } remote: { client, id in
            try await client.modifyThread(id: id, add: starring ? ["STARRED"] : [],
                                          remove: starring ? [] : ["STARRED"])
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
        mutateThreads(targets, local: { $0.isStarred = starring }, remote: { client, id in
            try await client.modifyThread(id: id, add: starring ? ["STARRED"] : [],
                                          remove: starring ? [] : ["STARRED"])
        })
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
        mutateThread(thread) { $0.isUnread = !read } remote: { client, id in
            try await client.modifyThread(id: id, add: read ? [] : ["UNREAD"],
                                          remove: read ? ["UNREAD"] : [])
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
        for thread in targets {
            setRead(thread, read: read)
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
            mutateThread(thread) { $0.snoozeUntil = nil; $0.inInbox = true } remote: { client, id in
                try await client.modifyThread(id: id, add: ["INBOX"])
            }
            return
        }
        // Tear the picker down *before* the optimistic mutation so auto-advance
        // publishes into a visible window (same frame as archive/trash).
        dismissSnoozePicker()
        mutateThread(thread, autoAdvanceAction: "snooze") {
            $0.snoozeUntil = date
            $0.inInbox = false
        } remote: { client, id in
            try await client.modifyThread(id: id, remove: ["INBOX"])
        }
        // Reuse the shared formatter path — allocating DateFormatter on the
        // triage hot path is needlessly expensive on the main thread.
        offerUndo(SnoozeDateParser.undoLabel(until: date)) { [weak self] in
            guard let self else { return }
            self.snooze(thread, until: nil)
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
        mutateThreads(targets, autoAdvanceAction: "snooze", local: {
            $0.snoozeUntil = date
            $0.inInbox = false
        }, remote: { client, id in
            try await client.modifyThread(id: id, remove: ["INBOX"])
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
            self.mutateThreads(targets, local: {
                $0.snoozeUntil = nil
                $0.inInbox = true
            }, remote: { client, id in
                try await client.modifyThread(id: id, add: ["INBOX"])
            })
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
