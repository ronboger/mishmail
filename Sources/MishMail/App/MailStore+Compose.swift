import Foundation
import SwiftUI
import AppKit
import GRDB

extension MailStore {
    // MARK: - Sending

    /// A composed message waiting out the undo-send window.
    struct PendingSend {
        /// Gmail API mailbox (OAuth account) — owns the threadId for replies.
        let accountId: String
        /// Address written in From: (primary or send-as of `accountId`).
        /// Empty means the primary (`accountId`).
        var fromEmail: String = ""
        let to: String
        let cc: String
        let bcc: String
        let subject: String
        let body: String
        let replyTo: Message?
        let forward: Bool
        /// Gmail Forward all — restored into the compose banner; HTML upgrade
        /// still re-detects from the body package if this is wrong/missing.
        var forwardAll: Bool = false
        let attachments: [MIMEBuilder.Attachment]
        let replacingDraft: Message?

        /// Effective From identity email.
        var effectiveFromEmail: String {
            fromEmail.isEmpty ? accountId : fromEmail
        }
    }

    /// Queue a message: it actually sends after `undoSendWindow` unless undone.
    func queueSend(_ pending: PendingSend) {
        guard !demoMode else {
            showNotice("Sending is disabled in the demo inbox")
            return
        }
        // A second send flushes the first immediately — one window at a time.
        if let previous = takePendingSend() {
            Task { await self.performSend(previous) }
        }
        pendingSend = pending
        setPendingDraftSuppressed(pending.replacingDraft, suppressed: true)
        undoTimer?.invalidate()
        undoAction = UndoAction(label: "Sending…") { [weak self] in self?.cancelPendingSend() }
        pendingSendTimer = Timer.scheduledTimer(withTimeInterval: Self.undoSendWindow,
                                                repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.flushPendingSend() }
        }
    }

    /// Undo: pull the message back into compose, nothing sent.
    func cancelPendingSend() {
        guard let p = takePendingSend() else { return }
        undoAction = nil
        setPendingDraftSuppressed(p.replacingDraft, suppressed: false)
        composeRequest = ComposeRequest(replyTo: p.replyTo, forward: p.forward,
                                        forwardAll: p.forwardAll,
                                        editDraft: p.replacingDraft, restore: p)
    }

    /// Send the queued message now (window elapsed, or the app is quitting).
    func flushPendingSend() async {
        guard let p = takePendingSend() else { return }
        undoAction = nil
        await performSend(p)
    }

    private func takePendingSend() -> PendingSend? {
        pendingSendTimer?.invalidate()
        pendingSendTimer = nil
        defer { pendingSend = nil }
        return pendingSend
    }

    private enum SendOutcome {
        case sent
        /// No network: the caller decides where the message waits.
        case deferredOffline
        /// Gmail rejected it; the message is back in compose with the error.
        case failed
    }

    /// Undo window elapsed. Offline, the message moves to the Scheduled list
    /// as "waiting for connection" and goes out on reconnect — the composer
    /// does not reopen with an error the user can do nothing about.
    private func performSend(_ p: PendingSend) async {
        switch await attemptSend(p) {
        case .sent, .failed:
            break
        case .deferredOffline:
            queueSendForReconnect(p)
        }
    }

    private func attemptSend(_ p: PendingSend) async -> SendOutcome {
        do {
            try await send(from: p.accountId, fromEmail: p.effectiveFromEmail,
                           to: p.to, cc: p.cc, bcc: p.bcc,
                           subject: p.subject, body: p.body, replyTo: p.replyTo,
                           forward: p.forward,
                           attachments: p.attachments, replacingDraft: p.replacingDraft)
            isOffline = false
            setPendingDraftSuppressed(p.replacingDraft, suppressed: false)
            showNotice("Sent")
            return .sent
        } catch {
            if OfflinePolicy.shouldDefer(error) {
                isOffline = true
                return .deferredOffline
            }
            // Bring the message back so nothing is lost.
            setPendingDraftSuppressed(p.replacingDraft, suppressed: false)
            lastError = "Send failed: \(error.localizedDescription)"
            composeRequest = ComposeRequest(replyTo: p.replyTo, forward: p.forward,
                                            forwardAll: p.forwardAll,
                                            editDraft: p.replacingDraft, restore: p)
            return .failed
        }
    }

    /// Park a send that found no network: a scheduled row due *now*, which
    /// the reconnect flush and the poll backstop both pick up.
    private func queueSendForReconnect(_ p: PendingSend) {
        let row = ScheduledSend(
            id: nil, accountId: p.accountId, fromEmail: p.effectiveFromEmail,
            toHeader: p.to, ccHeader: p.cc,
            bccHeader: p.bcc, subject: p.subject, body: p.body, sendAt: Date(),
            replyToMessageId: p.replyTo?.id, forward: p.forward,
            replacingDraftId: p.replacingDraft?.id,
            attachmentsJSON: ScheduledSend.encodeAttachments(p.attachments),
            createdAt: Date())
        do {
            try db.write { db in try row.insert(db) }
        } catch {
            // Last resort: back into compose rather than into the void.
            setPendingDraftSuppressed(p.replacingDraft, suppressed: false)
            lastError = "Send failed: \(error.localizedDescription)"
            composeRequest = ComposeRequest(replyTo: p.replyTo, forward: p.forward,
                                            forwardAll: p.forwardAll,
                                            editDraft: p.replacingDraft, restore: p)
            return
        }
        reloadScheduledSends()
        showNotice(OfflinePolicy.queuedSendNotice)
    }

    /// Update the local visibility before compose opens/closes. The underlying
    /// Gmail draft remains untouched until `send` commits after the Undo window.
    private func setPendingDraftSuppressed(_ draft: Message?, suppressed: Bool) {
        guard let draft else { return }
        if suppressed {
            suppressedDraftMessageIds.insert(draft.id)
            suppressedDraftThreadByMessageId[draft.id] = draft.threadId
        } else {
            suppressedDraftMessageIds.remove(draft.id)
            suppressedDraftThreadByMessageId.removeValue(forKey: draft.id)
        }
        // Suppression is applied to the payload the repository *returns*, never
        // baked into what it caches, so this invalidates no content revision.
        // Both sets are published — the open pane re-reads off them and hits
        // the same warm entry.
        _ = refreshDraftThreadSuppression(draft.threadId)
    }

    /// Drafts is thread-based, but suppression is message-based. Hide a row
    /// only when the thread has drafts and every one is pending; an unrelated
    /// sibling draft must remain reachable during another draft's Undo window.
    private func refreshDraftThreadSuppression(_ threadId: String) -> Bool {
        let draftIds: [String] = (try? db.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT id
                    FROM message
                    WHERE threadId = ?
                      AND (' ' || labelIds || ' ') LIKE '% DRAFT %'
                    """,
                arguments: [threadId])
        }) ?? []
        // Autosave may hand queueSend a fresh draft stand-in before the next
        // mailbox sync has inserted that row locally. Include pending IDs from
        // the in-memory map so a lone fresh draft still hides its Drafts row.
        let pendingDraftIds = suppressedDraftThreadByMessageId.compactMap {
            $0.value == threadId ? $0.key : nil
        }
        let knownDraftIds = Array(Set(draftIds).union(pendingDraftIds))
        let shouldSuppress = PendingDraftVisibility.suppressesThread(
            draftMessageIds: knownDraftIds,
            suppressing: suppressedDraftMessageIds)
        if shouldSuppress {
            return suppressedDraftThreadIds.insert(threadId).inserted
        }
        return suppressedDraftThreadIds.remove(threadId) != nil
    }

    // MARK: - Scheduled sends (send later)


    func reloadScheduledSends() {
        scheduledSends = (try? db.read {
            try ScheduledSend.order(Column("sendAt")).fetchAll($0)
        }) ?? []
        armScheduledSendTimer()
    }

    /// Persist a composed message to go out at `date`. Survives relaunch;
    /// anything overdue sends on next launch.
    func scheduleSend(_ p: PendingSend, at date: Date) {
        guard !demoMode else {
            showNotice("Scheduled sending is disabled in the demo inbox")
            return
        }
        let row = ScheduledSend(
            id: nil, accountId: p.accountId, fromEmail: p.effectiveFromEmail,
            toHeader: p.to, ccHeader: p.cc,
            bccHeader: p.bcc, subject: p.subject, body: p.body, sendAt: date,
            replyToMessageId: p.replyTo?.id, forward: p.forward,
            replacingDraftId: p.replacingDraft?.id,
            attachmentsJSON: ScheduledSend.encodeAttachments(p.attachments),
            createdAt: Date())
        try? db.write { db in try row.insert(db) }
        reloadScheduledSends()
        showNotice("Scheduled — sends \(SendSchedule.describe(date))")
    }

    /// Pull a scheduled message back into compose (nothing is lost).
    func editScheduledSend(_ s: ScheduledSend) {
        let p = pendingSend(from: s)
        try? db.write { db in _ = try ScheduledSend.deleteOne(db, key: s.id) }
        reloadScheduledSends()
        composeRequest = ComposeRequest(replyTo: p.replyTo, forward: p.forward,
                                        forwardAll: p.forwardAll,
                                        editDraft: p.replacingDraft, restore: p)
    }

    /// Skip the wait: goes through the normal undo-send window.
    func sendScheduledNow(_ s: ScheduledSend) {
        let p = pendingSend(from: s)
        try? db.write { db in _ = try ScheduledSend.deleteOne(db, key: s.id) }
        reloadScheduledSends()
        queueSend(p)
    }

    func discardScheduledSend(_ s: ScheduledSend) {
        try? db.write { db in _ = try ScheduledSend.deleteOne(db, key: s.id) }
        reloadScheduledSends()
        showNotice("Scheduled message discarded")
    }

    private func pendingSend(from s: ScheduledSend) -> PendingSend {
        // The referenced messages may have been pruned since; threading
        // headers then simply fall away. Bodies live off-row (v24) — use
        // messageBody so ReplyComposer/ForwardComposer can still match the
        // quote and emit Gmail-style HTML.
        let replyTo = s.replyToMessageId.flatMap { messageBody(id: $0) }
        let draft = s.replacingDraftId.flatMap { messageBody(id: $0) }
        return PendingSend(accountId: s.accountId, fromEmail: s.effectiveFromEmail,
                           to: s.toHeader, cc: s.ccHeader,
                           bcc: s.bccHeader, subject: s.subject, body: s.body,
                           replyTo: replyTo, forward: s.forward,
                           attachments: s.attachments, replacingDraft: draft)
    }

    private func armScheduledSendTimer() {
        scheduledSendTimer?.invalidate()
        scheduledSendTimer = nil
        guard let next = scheduledSends.map(\.sendAt).min() else { return }
        // A due row stays put when the send found no network, so the 1s floor
        // would re-arm this timer once a second for the whole flight.
        let delay = OfflinePolicy.scheduledSendRetryDelay(next: next, isOffline: isOffline)
        scheduledSendTimer = Timer.scheduledTimer(withTimeInterval: delay,
                                                  repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.fireDueScheduledSends() }
        }
    }

    /// Send everything whose time has come. A row that cannot go out for
    /// want of a network stays put (it reads "Waiting for connection" in the
    /// Scheduled list) and the loop stops — the rest would fail the same way.
    func fireDueScheduledSends() async {
        guard !demoMode, !isShuttingDown, !scheduledSendFlushInFlight else { return }
        scheduledSendFlushInFlight = true
        defer { scheduledSendFlushInFlight = false }
        let due = scheduledSends.filter { $0.sendAt <= Date() }
        guard !due.isEmpty else { return }
        for s in due {
            guard !isShuttingDown else { break }
            let p = pendingSend(from: s)
            let outcome = await attemptSend(p)
            if outcome == .deferredOffline { break }
            _ = try? await db.write { db in try ScheduledSend.deleteOne(db, key: s.id) }
            guard outcome == .sent else { continue }
            Notifier.notify(title: "Scheduled message sent",
                            body: s.subject.isEmpty ? s.toHeader : s.subject,
                            id: "scheduled.\(s.id ?? 0)")
        }
        reloadScheduledSends()
    }

    func send(from accountId: String, fromEmail: String = "",
              to: String, cc: String, bcc: String = "", subject: String,
              body: String, replyTo message: Message? = nil, forward: Bool = false,
              attachments: [MIMEBuilder.Attachment] = [],
              replacingDraft draft: Message? = nil) async throws {
        // For a forward, `message` is the forwarded original: it supplies the
        // HTML body below, but must not thread the send into its conversation.
        let threadParent = forward ? nil : message
        // Replies must send through the mailbox that owns the thread.
        // A mismatched From account used to pass a foreign threadId → Gmail 404.
        // Brand-new mail (even with an autosave draft on another mailbox)
        // honors `accountId` so a From change is not rewritten to the
        // original mailbox's default send-as.
        let apiAccountId = SendIdentityResolver.apiAccountId(
            requested: accountId,
            replyAccountId: threadParent?.accountId,
            draftAccountId: draft?.accountId)
        let identityEmail = fromEmail.isEmpty ? apiAccountId : fromEmail
        let bodyHTML = htmlAlternative(body: body,
                                       forwardOf: forward ? message : nil,
                                       replyTo: forward ? nil : message,
                                       draft: draft)
        let raw = MIMEBuilder.build(
            from: fromHeader(accountId: apiAccountId, fromEmail: identityEmail),
            to: to, cc: cc, bcc: bcc, subject: subject,
            bodyText: body, bodyHTML: bodyHTML,
            inReplyTo: threadParent?.messageIdHeader,
            references: threadParent?.referencesHeader ?? draft?.referencesHeader,
            attachments: attachments
        )
        // A reply keeps its thread; so does a draft that lives in one — but
        // only when the local composite is owned by apiAccountId. Stale /
        // foreign threadIds used to 404 messages.send (compose shows
        // "Send failed: Gmail API error 404").
        let gmailThreadId = SendThreading.apiThreadId(
            localThreadId: SendThreading.localThreadId(
                replyThreadId: threadParent?.threadId,
                draftThreadId: draft?.threadId),
            apiAccountId: apiAccountId)
        let gmail = client(for: apiAccountId)
        do {
            try await gmail.send(raw: raw, threadId: gmailThreadId)
        } catch {
            // Thread gone on the server (deleted draft-only conversation,
            // pruned history, etc.): still deliver as a new conversation.
            guard gmailThreadId != nil, SendThreading.isNotFound(error) else { throw error }
            try await gmail.send(raw: raw, threadId: nil)
        }
        if let draft { await deleteUnderlyingDraft(draft, silent: true) }
        await sync(accountId: apiAccountId)
    }

    /// HTML alternative for an outgoing message:
    /// 1. Untouched forward quote → original HTML under user text
    /// 2. Untouched reply quote → Gmail-style gmail_quote + original HTML
    /// 3. Unedited draft body → preserved draft HTML
    /// 4. Markdown body → rendered HTML (bold, headers, math, lists, …)
    /// 5. Otherwise → ComposeLinks linkification (markdown links + bare URLs)
    ///
    /// Forward single vs Forward-all is resolved by
    /// `ForwardComposer.matchHTMLUpgrade` (all-package first — see that
    /// method; drafts are excluded from Forward-all). Replies use
    /// `ReplyComposer` so nested history isn't re-markdown'd as `>` lines.
    private func htmlAlternative(body: String, forwardOf original: Message?,
                                 replyTo replyParent: Message? = nil,
                                 draft: Message?) -> String? {
        if let orig = original {
            let threadMsgs = messages(inThread: orig.threadId)
            if let match = ForwardComposer.matchHTMLUpgrade(
                body: body, original: orig, threadMessages: threadMsgs) {
                return ForwardComposer.htmlBody(userText: match.userText, parts: match.parts)
            }
            // Content drift (new mail in thread since compose) or an edited
            // quote: neither package matches → fall through to plain/markdown.
        }
        if let parent = replyParent,
           let match = ReplyComposer.matchHTMLUpgrade(body: body, original: parent) {
            return ReplyComposer.htmlBody(userText: match.userText, original: match.original)
        }
        if let draft, let html = draft.bodyHTML, !html.isEmpty, body == draft.bodyText {
            return html
        }
        // Markdown-authored body. Reply quotes that failed the upgrade above
        // still match `^>\s` here — best-effort, not Gmail-shaped.
        if Markdown.looksLikeMarkdown(body) {
            return Markdown.toHTML(body)
        }
        // Plain prose: still emit HTML when there are links to click.
        let fragment = ComposeLinks.htmlFragment(from: body)
        return fragment.isEmpty ? nil : fragment
    }

    /// Saves compose state as a real Gmail draft (shows up in Gmail too).
    /// Replaces `replacing` when re-saving an edited draft.
    /// - Parameter silent: skip the success toast (autosave / status UI owns feedback).
    /// - Parameter syncAfter: refresh local DB after save. Defaults to `!silent`
    ///   so autosave stays light; dismiss paths pass `true` so Drafts/thread
    ///   rows match Gmail (no stale "continue draft" after replace).
    /// - Returns: a lightweight Message stand-in for the new draft so the
    ///   next autosave can replace it without waiting on a full sync.
    @discardableResult
    func saveDraft(from accountId: String, fromEmail: String = "",
                   to: String, cc: String, bcc: String = "", subject: String,
                   body: String, replyTo message: Message? = nil, forward: Bool = false,
                   attachments: [MIMEBuilder.Attachment] = [],
                   replacing draft: Message? = nil,
                   silent: Bool = false,
                   syncAfter: Bool? = nil) async -> Message? {
        let shouldSync = syncAfter ?? !silent
        guard !demoMode else {
            if !silent { showNotice("Drafts aren't saved in the demo inbox") }
            return nil
        }
        // Same rules as send(): a forward's original doesn't thread the
        // draft, but supplies the HTML body when the quote is untouched.
        let threadParent = forward ? nil : message
        // Same mailbox rule as send(): replies stay put; new mail follows
        // the selected From even when replacing a draft on another mailbox.
        let apiAccountId = SendIdentityResolver.apiAccountId(
            requested: accountId,
            replyAccountId: threadParent?.accountId,
            draftAccountId: draft?.accountId)
        let identityEmail = fromEmail.isEmpty ? apiAccountId : fromEmail
        let raw = MIMEBuilder.build(
            from: fromHeader(accountId: apiAccountId, fromEmail: identityEmail),
            to: to, cc: cc, bcc: bcc, subject: subject, bodyText: body,
            bodyHTML: htmlAlternative(body: body,
                                      forwardOf: forward ? message : nil,
                                      replyTo: forward ? nil : message,
                                      draft: draft),
            inReplyTo: threadParent?.messageIdHeader,
            references: threadParent?.referencesHeader ?? draft?.referencesHeader,
            attachments: attachments
        )
        let gmailThreadId = SendThreading.apiThreadId(
            localThreadId: SendThreading.localThreadId(
                replyThreadId: threadParent?.threadId,
                draftThreadId: draft?.threadId),
            apiAccountId: apiAccountId)
        do {
            let gmail = client(for: apiAccountId)
            let created: GmailClient.GDraftRef
            // When createDraft 404s on a stale threadId we retry without it;
            // the stand-in must then use Gmail's *new* thread, not the dead one.
            var keptExistingThread = gmailThreadId != nil
            do {
                created = try await gmail.createDraft(raw: raw, threadId: gmailThreadId)
            } catch {
                // Same 404 fallback as send: stale draft thread → save as new.
                guard gmailThreadId != nil, SendThreading.isNotFound(error) else { throw error }
                created = try await gmail.createDraft(raw: raw, threadId: nil)
                keptExistingThread = false
            }
            if let draft { await deleteUnderlyingDraft(draft, silent: true) }
            if !silent {
                showNotice("Draft saved — find it in Drafts")
            }
            if shouldSync {
                await sync(accountId: apiAccountId)
            }
            // Stand-in for replace chaining. Prefer the local account-prefixed
            // id we already know only when Gmail actually accepted that thread.
            let localThreadId: String
            if keptExistingThread,
               let known = threadParent?.threadId ?? draft?.threadId {
                localThreadId = known
            } else {
                localThreadId = "\(apiAccountId):\(created.message.threadId)"
            }
            return Message(
                id: "\(apiAccountId):\(created.message.id)",
                accountId: apiAccountId,
                gmailId: created.message.id,
                threadId: localThreadId,
                fromHeader: fromHeader(accountId: apiAccountId, fromEmail: identityEmail),
                toHeader: to, ccHeader: cc, bccHeader: bcc,
                subject: subject, date: Date(), snippet: String(body.prefix(120)),
                bodyText: body, bodyHTML: nil,
                messageIdHeader: "", referencesHeader: "",
                labelIds: "DRAFT", isUnread: false, hasAttachment: !attachments.isEmpty)
        } catch {
            lastDraftSaveError = error
            // Always surface close-path failures (silent=false). Autosave keeps
            // lastError clean and uses the in-card "Draft not saved" status.
            // Connectivity failures never reach the banner: the caller keeps
            // the draft locally instead (see `persistDraft`).
            if !silent, OfflinePolicy.surfacesSyncFailure(error) {
                lastError = "Draft not saved: \(error.localizedDescription)"
            }
            return nil
        }
    }

    /// Where a compose draft ended up.
    enum DraftSaveOutcome {
        /// A real Gmail draft (the replace chain continues from it).
        case uploaded(Message)
        /// No network: kept in the Outbox; `flushLocalDrafts` uploads it.
        case keptLocally(LocalDraft)
        /// Gmail rejected it (lastError set on the close path).
        case failed
    }

    /// `saveDraft` with the offline fallback the composer needs: a draft that
    /// cannot reach Gmail is written to `localDraft` (updating `local` in
    /// place when this compose already owns an Outbox row) so closing the
    /// card on a plane never drops the text. A later save that *does* reach
    /// Gmail deletes the Outbox row.
    func persistDraft(from accountId: String, fromEmail: String = "",
                      to: String, cc: String, bcc: String = "", subject: String,
                      body: String, replyTo message: Message? = nil, forward: Bool = false,
                      forwardAll: Bool = false,
                      attachments: [MIMEBuilder.Attachment] = [],
                      replacing draft: Message? = nil,
                      local: LocalDraft? = nil,
                      silent: Bool = false,
                      syncAfter: Bool? = nil) async -> DraftSaveOutcome {
        if !isOffline {
            lastDraftSaveError = nil
            if let saved = await saveDraft(from: accountId, fromEmail: fromEmail,
                                           to: to, cc: cc, bcc: bcc, subject: subject,
                                           body: body, replyTo: message, forward: forward,
                                           attachments: attachments, replacing: draft,
                                           silent: silent, syncAfter: syncAfter) {
                if let local { deleteLocalDraft(local, silent: true) }
                isOffline = false
                return .uploaded(saved)
            }
            guard let error = lastDraftSaveError, OfflinePolicy.shouldDefer(error) else {
                return .failed
            }
            isOffline = true
        }
        let now = Date()
        var row = local ?? LocalDraft(
            id: nil, accountId: accountId, fromEmail: fromEmail,
            toHeader: to, ccHeader: cc, bccHeader: bcc, subject: subject, body: body,
            replyToMessageId: message?.id, forward: forward, forwardAll: forwardAll,
            replacingDraftId: draft?.id,
            attachmentsJSON: ScheduledSend.encodeAttachments(attachments),
            createdAt: now, updatedAt: now)
        row.accountId = accountId
        row.fromEmail = fromEmail
        row.toHeader = to; row.ccHeader = cc; row.bccHeader = bcc
        row.subject = subject; row.body = body
        row.replyToMessageId = message?.id
        row.forward = forward; row.forwardAll = forwardAll
        row.replacingDraftId = draft?.id
        row.attachmentsJSON = ScheduledSend.encodeAttachments(attachments)
        row.updatedAt = now
        let stored: LocalDraft
        let pending = row
        do {
            stored = try await db.write { db -> LocalDraft in
                var saved = pending
                // Update in place only while the row is still there. The
                // reconnect flush (or a Discard) can retire it between two
                // autosaves; `update` would then throw and the composer would
                // report "Draft not saved" with the text nowhere on disk.
                var exists = false
                if let id = saved.id {
                    exists = try LocalDraft.filter(Column("id") == id).fetchCount(db) > 0
                }
                if exists {
                    try saved.update(db)
                } else {
                    // Read the rowid back explicitly: the composer keys every
                    // later autosave on it, and a nil id would stack copies.
                    saved.id = nil
                    try saved.insert(db)
                    saved.id = db.lastInsertedRowID
                }
                return saved
            }
        } catch {
            if !silent { lastError = "Draft not saved: \(error.localizedDescription)" }
            return .failed
        }
        reloadLocalDrafts()
        if !silent { showNotice(OfflinePolicy.localDraftNotice) }
        return .keptLocally(stored)
    }

    // MARK: - Outbox (drafts saved offline)

    func reloadLocalDrafts() {
        localDrafts = (try? db.read {
            try LocalDraft.order(Column("updatedAt").desc).fetchAll($0)
        }) ?? []
    }

    /// Reopen an Outbox draft in compose. The row stays until the editor
    /// uploads or discards it; autosave keeps updating it while offline.
    func editLocalDraft(_ local: LocalDraft) {
        let replyTo = local.replyToMessageId.flatMap { messageBody(id: $0) }
        let draft = local.replacingDraftId.flatMap { messageBody(id: $0) }
        let restore = PendingSend(accountId: local.accountId, fromEmail: local.effectiveFromEmail,
                                  to: local.toHeader, cc: local.ccHeader,
                                  bcc: local.bccHeader, subject: local.subject, body: local.body,
                                  replyTo: replyTo, forward: local.forward,
                                  forwardAll: local.forwardAll,
                                  attachments: local.attachments, replacingDraft: draft)
        var request = ComposeRequest(replyTo: replyTo, forward: local.forward,
                                     forwardAll: local.forwardAll,
                                     editDraft: draft, restore: restore)
        request.localDraft = local
        openCompose(request)
    }

    func deleteLocalDraft(_ local: LocalDraft, silent: Bool = false) {
        guard let id = local.id else { return }
        try? db.write { db in _ = try LocalDraft.deleteOne(db, key: id) }
        if composingLocalDraftId == id { composingLocalDraftId = nil }
        reloadLocalDrafts()
        if !silent { showNotice("Offline draft discarded") }
    }

    /// Upload Outbox drafts as real Gmail drafts, oldest first, skipping the
    /// one open in compose (its editor owns it). Stops at the first
    /// connectivity failure. One Drafts-mailbox sync afterwards so the
    /// uploaded rows appear where the user expects them.
    func flushLocalDrafts() async {
        guard !demoMode, !isShuttingDown, !localDraftFlushInFlight else { return }
        localDraftFlushInFlight = true
        defer { localDraftFlushInFlight = false }
        let rows = (try? await db.read {
            try LocalDraft.order(Column("createdAt")).fetchAll($0)
        }) ?? []
        guard !rows.isEmpty else {
            if !localDrafts.isEmpty { reloadLocalDrafts() }
            return
        }
        var uploadedAccounts: Set<String> = []
        var uploadedCount = 0
        for local in rows where local.id != composingLocalDraftId {
            guard !isShuttingDown else { break }
            let replyTo = local.replyToMessageId.flatMap { messageBody(id: $0) }
            let draft = local.replacingDraftId.flatMap { messageBody(id: $0) }
            lastDraftSaveError = nil
            let saved = await saveDraft(from: local.accountId, fromEmail: local.fromEmail,
                                        to: local.toHeader, cc: local.ccHeader,
                                        bcc: local.bccHeader, subject: local.subject,
                                        body: local.body, replyTo: replyTo,
                                        forward: local.forward,
                                        attachments: local.attachments, replacing: draft,
                                        silent: true, syncAfter: false)
            if saved != nil {
                isOffline = false
                uploadedAccounts.insert(local.accountId)
                uploadedCount += 1
                deleteLocalDraft(local, silent: true)
                continue
            }
            if let error = lastDraftSaveError, OfflinePolicy.shouldDefer(error) {
                isOffline = true
                break
            }
            if let error = lastDraftSaveError, AccountLifecycle.isReauthRequired(error) {
                requireReauthorization(for: local.accountId)
                break
            }
            // Rejected outright: keep the row so the user can open and fix it.
            if let error = lastDraftSaveError {
                lastError = "Couldn't upload an offline draft: \(error.localizedDescription)"
            }
        }
        for account in uploadedAccounts {
            await syncDraftMailbox(account)
        }
        if uploadedCount > 0 {
            showNotice(uploadedCount == 1 ? "Offline draft uploaded to Drafts"
                                          : "\(uploadedCount) offline drafts uploaded to Drafts")
        }
    }

    /// Lightweight sync after a silent autosave session ends (✕ / Esc / replace).
    func syncDraftMailbox(_ accountId: String) async {
        guard !demoMode, !accountId.isEmpty else { return }
        await sync(accountId: accountId)
    }

    // MARK: - Draft management

    /// Newest non-draft in a thread — thin wrapper over
    /// `ForwardComposer.newestSentMessage` for callers that already hold the store.
    func newestSentMessage(inThread threadId: String) -> Message? {
        ForwardComposer.newestSentMessage(in: messages(inThread: threadId))
    }

    /// Newest draft in a thread.
    func newestDraft(inThread threadId: String) -> Message? {
        ForwardComposer.newestDraft(in: messages(inThread: threadId))
    }

    /// A thread that is nothing but an unsent draft — opening it should hop
    /// straight into compose (Notion Mail-style), not the reading pane.
    /// Draft replies inside real conversations still open the thread.
    /// Discarded `DRAFT TRASH` rows alone are trash, not a live draft-only hop.
    func isDraftOnly(_ thread: MailThread) -> Bool {
        // `inDrafts` ignores discarded DRAFT+TRASH in the historical union.
        guard thread.inDrafts else { return false }
        let msgs = messages(inThread: thread.id)
        return !msgs.isEmpty && msgs.allSatisfy { ForwardComposer.isLiveDraft($0.labelIds) }
    }

    /// Opens a specific draft back into compose. Reply drafts recover the
    /// parent message so send still attaches In-Reply-To and the Gmail-style
    /// HTML upgrade; forward / brand-new-compose drafts leave replyTo nil.
    func editDraft(_ draft: Message) {
        guard ForwardComposer.isLiveDraft(draft.labelIds) else { return }
        let msgs = messages(inThread: draft.threadId)
        // Prefer the in-memory full body when the card was header-only.
        let full = messageBody(id: draft.id) ?? draft
        let parent = Self.replyParent(forDraft: full, inThread: msgs)
        openCompose(ComposeRequest(replyTo: parent, editDraft: full))
    }

    /// Draft ids currently open in a compose editor. The in-thread draft card
    /// and the slim draft banner hide these so Continue doesn't leave a
    /// duplicate of the editor's own content in the conversation.
    var composingDraftMessageIds: Set<String> {
        composingDraftIdsByRequest.values.reduce(into: Set<String>()) {
            $0.formUnion($1)
        }
    }

    /// Compose claims the draft it is editing (and each autosave replacement).
    /// Late autosaves from a card that was already replaced/closed are ignored
    /// so a dead requestId cannot permanently re-hide the draft card.
    func noteComposingDraft(_ id: String?, requestId: UUID) {
        guard let id else { return }
        guard ComposingDraftVisibility.acceptsComposingNote(
            requestId: requestId,
            activeComposeRequestId: composeRequest?.id) else { return }
        composingDraftIdsByRequest[requestId, default: []].insert(id)
    }

    /// Compose card unmounted — its draft card may show again.
    func endComposingDrafts(requestId: UUID) {
        composingDraftIdsByRequest.removeValue(forKey: requestId)
    }

    /// Opens the newest draft in a thread (list/context-menu / top-banner entry).
    /// Prefer a live draft that is not already open in compose so the
    /// long-thread banner (shown when a sibling is unsent) doesn't re-open
    /// the draft you're already editing.
    func editDraft(inThread thread: MailThread) {
        let msgs = messages(inThread: thread.id)
        let composing = composingDraftMessageIds
        let candidate = msgs
            .filter { ForwardComposer.isLiveDraft($0.labelIds) }
            .filter { !composing.contains($0.id) }
            .max(by: { $0.date < $1.date })
            ?? newestDraft(inThread: thread.id)
        guard let draft = candidate else { return }
        editDraft(draft)
    }

    /// Latest non-draft message to thread a reopened reply draft against.
    /// Nil for forward drafts (body carries the forward marker / Fwd: subject)
    /// and for draft-only threads (new compose never left the box).
    static func replyParent(forDraft draft: Message, inThread msgs: [Message]) -> Message? {
        ComposeDrafts.replyParent(forDraft: draft, inThread: msgs)
    }

    /// Deletes the Gmail draft behind a local draft message.
    ///
    /// Local row is removed first so Discard cannot leave a stuck card when
    /// `drafts.list` has no match (orphaned local, already-trashed DRAFT, race
    /// after replace). Remote delete is best-effort after that.
    func deleteUnderlyingDraft(_ draftMessage: Message, silent: Bool = false) async {
        removeLocalDraftMessage(draftMessage, refreshList: !silent)

        guard !demoMode else {
            if !silent { showNotice("Draft deleted") }
            return
        }

        do {
            let client = client(for: draftMessage.accountId)
            let drafts = try await client.listDrafts()
            let refs = drafts.map { (id: $0.id, messageId: $0.message.id) }
            if let draftId = ForwardComposer.remoteDraftId(
                forGmailMessageId: draftMessage.gmailId, drafts: refs) {
                try await client.deleteDraft(id: draftId)
            }
            // No list match: already gone on the server — local row is enough.
            if !silent {
                showNotice("Draft deleted")
                await sync(accountId: draftMessage.accountId)
            }
        } catch {
            // Local is already gone for this session. A failed remote delete
            // can still resurrect the row on the next successful sync; the
            // non-silent path surfaces lastError so the user knows.
            if !silent { lastError = error.localizedDescription }
        }
    }

    /// Drop a draft message row and re-derive (or delete) its thread so the
    /// open reading pane and denorm flags update without waiting on history.
    /// Extracted static core is unit-tested against an in-memory DB.
    private func removeLocalDraftMessage(_ draftMessage: Message, refreshList: Bool) {
        let threadId = draftMessage.threadId
        let accountId = draftMessage.accountId
        let outcome = (try? db.write { db in
            try SyncEngine.deleteLocalMessage(
                db, messageId: draftMessage.id, threadId: threadId, accountId: accountId)
        }) ?? .missing
        guard outcome != .missing else { return }
        applyThreadContentChange(.threads([threadId]))
        Task { await threadDetailRepository.drop(threadId: threadId) }
        if refreshList {
            reloadThreads()
        } else if outcome == .threadDeleted {
            // Silent paths (send / replace) leave selection alone so the
            // follow-up sync can re-seat the thread without yanking to row 0.
            threads.removeAll { $0.id == threadId }
        } else if let updated = try? db.read({ try MailThread.fetchOne($0, key: threadId) }),
                  let idx = threads.firstIndex(where: { $0.id == threadId }) {
            threads[idx] = updated
        }
    }

    /// Discard a specific draft (card-level Discard / confirmed alert).
    func deleteDraft(_ draft: Message) {
        Task { await deleteUnderlyingDraft(draft) }
    }

    /// Discard the newest draft in a thread (list context menu).
    func deleteDraft(inThread thread: MailThread) {
        guard let draft = newestDraft(inThread: thread.id) else { return }
        deleteDraft(draft)
    }

    /// Download every attachment on a message into a folder the user picks.
    func saveAllAttachments(_ attachments: [AttachmentRow], message: Message) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save \(attachments.count) Attachments Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        Task {
            do {
                for att in attachments {
                    let data = try await downloadAttachment(att, message: message)
                    let dest = Self.availableAttachmentURL(
                        in: dir, filename: MessageParser.safeFilename(att.filename))
                    try data.write(to: dest, options: .atomic)
                    Self.markQuarantined(dest)
                }
                await MainActor.run {
                    showNotice("Saved \(attachments.count) attachments")
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
        }
    }
}
