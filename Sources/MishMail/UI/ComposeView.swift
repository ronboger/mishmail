import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Notion/Gmail-style compose: a docked card with recipient chips,
/// borderless fields, minimal footer.
struct ComposeView: View {
    @Environment(MailStore.self) var store

    let request: MailStore.ComposeRequest

    /// The message being replied to (nil for new mail and forwards' threading).
    private var replyTo: Message? { request.forward ? nil : request.replyTo }
    /// The original message, whatever the mode.
    private var original: Message? { request.replyTo }
    /// The Gmail draft being edited, if any.
    private var editingDraft: Message? { request.editDraft }

    /// Selected From identity email (primary or send-as). The API mailbox is
    /// derived from this identity — never switch GmailClient independently.
    @State private var fromEmail: String = ""
    /// OAuth mailbox that owns `fromEmail` (and any reply threadId).
    @State private var fromAccountId: String = ""
    @State private var toTokens: [String] = []
    @State private var toDraft = ""
    @State private var ccTokens: [String] = []
    @State private var ccDraft = ""
    @State private var showCc = false
    @State private var bccTokens: [String] = []
    @State private var bccDraft = ""
    @State private var showBcc = false
    @State private var subject: String = ""
    @State private var body_: String = ""
    /// The quoted original (reply quote or forward block), kept out of the
    /// editor behind a Gmail-style "…" button so the cursor starts at the top
    /// and the quote can't be edited by accident. Emptied on expand.
    @State private var quotedTail: String = ""
    @State private var attachmentURLs: [URL] = []
    /// Attachments carried back from an undone send, or pulled off the
    /// original message on a forward (data already loaded).
    @State private var restoredAttachments: [MIMEBuilder.Attachment] = []
    /// Filenames prefilled by a forward — not user-authored content.
    @State private var prefilledAttachmentNames: [String] = []
    /// Original attachments still downloading (forwards) — send waits.
    @State private var loadingAttachments = false
    @State private var showFilePicker = false
    @State private var showSnippets = false
    /// Slash trigger: highlighted row in the `/` picker (by stable list id),
    /// and whether the user Esc-dismissed the current token (cleared when the
    /// token goes away).
    @State private var slashSelectionId: String?
    @State private var slashDismissed = false
    /// UTF-16 caret in the body editor — drives caret-aware `/` detection.
    @State private var bodyCaretUTF16 = 0
    /// UTF-16 body selection, mirrored from the live NSTextView so inline AI
    /// edits can be enabled only when there is text to replace.
    @State private var bodySelection = NSRange(location: 0, length: 0)
    /// Local keyDown monitor that steals ↑/↓/Return/Tab/Esc while the `/`
    /// picker is up — the NSTextView behind TextEditor consumes those keys
    /// before SwiftUI's onKeyPress ever sees them.
    @State private var slashKeyMonitor: Any?
    @State private var showScheduleSheet = false
    /// ⌘K link sheet — UTF-16 offsets into `body_` captured when the sheet opens.
    @State private var showLinkSheet = false
    @State private var linkSelLocation = 0
    @State private var linkSelLength = 0
    @State private var linkInitialText = ""
    @State private var linkInitialURL = ""
    @State private var linkIsEditing = false
    @State private var drafting = false
    @State private var error: String?
    /// Suggested replies for an empty reply body (chips above the quote pill).
    @State private var suggestedReplies: [String] = []
    @State private var suggestionsLoading = false
    @State private var suggestionsError: String?
    @State private var suggestionsTask: Task<Void, Never>?
    /// User closed the strip for this compose (also set by picking a chip).
    @State private var suggestionsDismissed = false
    /// Set once per compose so the auto-trigger never re-fires; the strip's
    /// refresh button calls suggestReplies() directly instead.
    @State private var suggestionsRequested = false
    /// Guards late MainActor writes from a cancelled stream (regenerate).
    @State private var suggestionsGeneration = 0
    /// Captured when a generation starts — resolving per render would re-read
    /// and re-decode the provider list from UserDefaults on every keystroke.
    @State private var suggestionsModelName: String?
    @AppStorage(MailStore.suggestRepliesKey) private var suggestRepliesEnabled = true
    /// Body focus is a plain Bool (not FocusState) because the body is an
    /// AppKit NSTextView — FocusState doesn't attach to NSViewRepresentable.
    @State private var bodyFocused = false
    /// Bridge so the format toolbar mutates the live text view + selection.
    @State private var formatTarget = ComposeBodyFormatTarget()
    /// Comma-separated raw values of footer / format buttons the user hid
    /// (Settings → Appearance → Compose toolbar). Empty = show all.
    @AppStorage(ComposeToolbarVisibility.storageKey) private var composeToolbarHidden = ""

    @State private var initialBody = ""
    @State private var initialSubject = ""
    @State private var initialRecipients: [String] = []
    /// Collapsed to a title strip — draft fields stay mounted (state preserved).
    @State private var isMinimized = false
    /// Set by every explicit exit (send, schedule, discard, close). When the
    /// card unmounts without it — a new compose/reply request replaced this
    /// one, which single-key shortcuts allow while minimized — onDisappear
    /// saves the draft instead of silently dropping it.
    @State private var didFinish = false
    /// Live draft Gmail message to replace on the next save (starts as
    /// `editDraft` / undo restore, then tracks each successful autosave).
    /// Thread this into Send, Discard, and replace — never only into autosave.
    @State private var replacingDraft: Message?
    /// Notion-style footer status after typing.
    @State private var draftStatus: DraftSaveStatus = .idle
    /// Cached warmness of the reply target (Hey vs Hi vs Hello). Computed once
    /// in `prefill` — not on every body keystroke (stripping HTML is not free).
    @State private var greetingTone: GreetingAutocomplete.Tone = .neutral
    /// Debounced "save soon" timer (typing).
    @State private var autosaveTask: Task<Void, Never>?
    /// Serialized persist chain (latest-wins after in-flight completes).
    @State private var persistTask: Task<Void, Never>?
    /// Snapshot of fields last successfully saved — skip no-op autosaves.
    @State private var lastSavedFingerprint = ""
    /// True after a silent autosave succeeded this session (close should sync).
    @State private var didSilentSave = false

    private enum DraftSaveStatus: Equatable {
        case idle
        case saving
        case saved
        case failed
    }

    private var isInline: Bool { request.presentation == .inline }
    private var isSplit: Bool { request.presentation == .split }
    /// Pane fill is layout-derived from floating (empty reading pane); the
    /// request stays `.floating` so minimize / Gmail card chrome still apply.

    /// Draft id chain for replace / send / discard (autosave may have moved it).
    private var liveDraft: Message? { replacingDraft ?? editingDraft }

    /// Claim the finish path immediately (before any await) so Send / Esc /
    /// Discard / Schedule can't re-enter and double-queue. Returns false if
    /// another finish is already in flight.
    ///
    /// Also yields the keyboard: resign text focus and mark
    /// `store.composeFinishing` so mailbox keys (`e`, `g i`, …) work while a
    /// discard/save path still awaits persist — Send itself unmounts without
    /// that wait.
    @discardableResult
    private func beginFinish() -> Bool {
        guard !didFinish else { return false }
        didFinish = true
        autosaveTask?.cancel()
        autosaveTask = nil
        bodyFocused = false
        showSnippets = false
        showLinkSheet = false
        showScheduleSheet = false
        store.composeFinishing = true
        store.slashPickerVisible = false
        NSApp.keyWindow?.makeFirstResponder(nil)
        return true
    }

    /// Undo `beginFinish` when the action can't complete (e.g. empty To:).
    private func abortFinish() {
        didFinish = false
        // Only clear the flag if this card is still the mounted request —
        // a newer compose opened during finish already reset it.
        if store.composeRequest?.id == request.id {
            store.composeFinishing = false
        }
        // Send cancels autosave before packaging; re-arm so unsaved content
        // still lands in Drafts if the user keeps editing after abort.
        if hasContent { scheduleAutosave() }
        // beginFinish resigned focus so mailbox keys would work; put the
        // caret back so the re-enabled card is usable without a click.
        focusBody()
    }

    /// Dismiss this card only if it is still the store's active request.
    /// Finish tasks await persist and can outlive a user who opened a new
    /// compose via `g i` + reply (or `c`) during the finish window — a bare
    /// clear would yank the new card mid-typing.
    private func close() {
        didFinish = true
        autosaveTask?.cancel()
        autosaveTask = nil
        guard store.composeRequest?.id == request.id else { return }
        // clearComposeRequest (not a bare nil) flushes a queued mailto: from
        // an external link that waited on this expanded draft; also clears
        // composeFinishing.
        store.clearComposeRequest()
    }

    /// Title shown in the header and minimized strip.
    private var headerTitle: String {
        if liveDraft != nil {
            return "Draft: \(subject.isEmpty ? "(no subject)" : subject)"
        }
        return subject.isEmpty ? "New Message" : subject
    }

    /// Collapse or restore the compose card. Resigns text focus when
    /// minimizing so mailbox shortcuts (j/k, archive, …) work again.
    private func setMinimized(_ value: Bool) {
        guard isMinimized != value else { return }
        isMinimized = value
        store.composeMinimized = value
        if value {
            bodyFocused = false
            showSnippets = false
            showLinkSheet = false
            showScheduleSheet = false
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    /// The complete message body: what's in the editor plus the collapsed
    /// quote, joined exactly the way the old inline prefill did ("\n\n" +
    /// quote) so the send path still recognizes an untouched forward block.
    private var fullBody: String {
        quotedTail.isEmpty ? body_ : body_ + "\n\n" + quotedTail
    }

    /// While the quote is collapsed, size the body editor to the authored
    /// text so a normal reply (greeting + a few lines + sign-off) fits
    /// without internal scroll — the "…" pill stays just under the text
    /// instead of floating in empty chrome. Math lives in
    /// `ComposeBodyLayout` (unit-tested): modest empty floor, content+slack
    /// when typing, slash band for the `/` picker.
    private var bodyEditorMaxHeight: CGFloat {
        ComposeBodyLayout.editorHeights(
            body: body_,
            hasCollapsedQuote: !quotedTail.isEmpty,
            slashActive: slashActive,
            // Compact cards cap long replies so their footer stays visible.
            // Split compose already fills the window: use that available
            // height before introducing an internal editor scrollbar.
            collapsedQuoteCap: isSplit ? .infinity
                                       : ComposeBodyLayout.collapsedCap).max
    }

    /// Body editor minimum — mirrors `bodyEditorMaxHeight` so short replies
    /// hug content (no 180pt void under two lines) while empty replies keep
    /// a usable writing surface.
    private var bodyEditorMinHeight: CGFloat {
        ComposeBodyLayout.editorHeights(
            body: body_,
            hasCollapsedQuote: !quotedTail.isEmpty,
            slashActive: slashActive,
            collapsedQuoteCap: isSplit ? .infinity
                                       : ComposeBodyLayout.collapsedCap).min
    }

    /// Focuses the body editor. Setting the FocusState synchronously in
    /// onAppear fires before the TextEditor is ready and gets dropped —
    /// same trick as AddressField's autoFocus, delayed a beat.
    ///
    /// Never re-arm focus after `beginFinish` — a delayed re-steal on an
    /// still-editable body would make `TextFocus.isEditing` swallow mailbox
    /// keys (post-Send archive) until the card unmounts.
    private func focusBody() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard !didFinish else { return }
            bodyFocused = true
        }
    }

    /// Inlines the collapsed quote into the editor, making it editable.
    private func expandQuote() {
        guard !quotedTail.isEmpty else { return }
        // Caret stays where it was in the head (still a valid offset).
        setBody(fullBody, caretUTF16: bodyCaretUTF16)
        // The quote is still prefill, not authored content.
        initialBody = "\n\n" + quotedTail
        quotedTail = ""
    }

    /// Where an inlined quoted original starts in the editor, if any.
    private var quoteStartInBody: String.Index? {
        (body_.range(of: "\n" + ForwardComposer.marker)
            ?? body_.range(of: #"\n+On .+ wrote:\n"#, options: .regularExpression))?
            .lowerBound
    }

    /// Splits the quoted original back out of the editor, re-collapsing it
    /// behind the "…" pill. Inverse of expandQuote; edits the user made to
    /// the quote while it was expanded travel with it.
    private func collapseQuote() {
        guard quotedTail.isEmpty, let start = quoteStartInBody else { return }
        let untouched = body_.trimmingCharacters(in: .whitespacesAndNewlines)
            == initialBody.trimmingCharacters(in: .whitespacesAndNewlines)
        var tail = String(body_[start...])
        while tail.first == "\n" { tail.removeFirst() }
        guard !tail.isEmpty else { return }
        quotedTail = tail
        var head = String(body_[..<start])
        while head.last == "\n" { head.removeLast() }
        // If the caret was inside the quote, park it at end of authored head.
        let headLen = (head as NSString).length
        setBody(head, caretUTF16: min(bodyCaretUTF16, headLen))
        // A never-edited body collapses back to pure prefill.
        if untouched { initialBody = "" }
    }

    /// Rewrite the body and park the caret. Every programmatic `body_` write
    /// goes through here so ComposeBodyEditor's rewrite path never teleports
    /// the caret to a stale `caretUTF16` left over from a prior edit.
    private func setBody(_ newBody: String, caretUTF16: Int) {
        let maxLen = (newBody as NSString).length
        let caret = max(0, min(caretUTF16, maxLen))
        body_ = newBody
        bodyCaretUTF16 = caret
        let nextSelection = NSRange(location: caret, length: 0)
        if bodySelection != nextSelection {
            bodySelection = nextSelection
        }
    }

    /// Content the user actually authored (quoted/reply prefill doesn't count).
    private var hasContent: Bool {
        editingDraft != nil
            || toTokens + ccTokens + bccTokens != initialRecipients
            || !toDraft.trimmingCharacters(in: .whitespaces).isEmpty
            || !ccDraft.trimmingCharacters(in: .whitespaces).isEmpty
            || !bccDraft.trimmingCharacters(in: .whitespaces).isEmpty
            || subject != initialSubject
            || body_.trimmingCharacters(in: .whitespacesAndNewlines)
                != initialBody.trimmingCharacters(in: .whitespacesAndNewlines)
            || !attachmentURLs.isEmpty
            || restoredAttachments.map(\.filename) != prefilledAttachmentNames
    }

    /// Fingerprint of fields that participate in draft persistence.
    private var contentFingerprint: String {
        [fromEmail, toTokens.joined(separator: ","), ccTokens.joined(separator: ","),
         bccTokens.joined(separator: ","), subject, fullBody,
         attachmentURLs.map(\.lastPathComponent).joined(separator: "|"),
         restoredAttachments.map(\.filename).joined(separator: "|")]
            .joined(separator: "\u{1e}")
    }

    /// Schedule a debounced silent autosave after the user types.
    private func scheduleAutosave() {
        // Always cancel a pending debounce first — even when content reverts to
        // the last-saved fingerprint, so a stale timer can't flip status later.
        autosaveTask?.cancel()
        autosaveTask = nil
        // Demo has nowhere to persist; don't claim "Draft saved".
        guard !store.demoMode else {
            draftStatus = .idle
            return
        }
        guard hasContent else {
            draftStatus = .idle
            return
        }
        // Already saved this exact content.
        if contentFingerprint == lastSavedFingerprint {
            draftStatus = .saved
            return
        }
        draftStatus = draftStatus == .saved ? .idle : draftStatus
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await enqueuePersist(silent: true, syncAfter: false)
        }
    }

    /// Serialize persists so concurrent autosave + close/send never both
    /// createDraft against the same `replacingDraft` (duplicate Gmail drafts).
    @MainActor
    private func enqueuePersist(silent: Bool, syncAfter: Bool) async {
        let previous = persistTask
        let task = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await performPersist(silent: silent, syncAfter: syncAfter)
        }
        persistTask = task
        await task.value
        if persistTask == task { persistTask = nil }
    }

    /// Wait for any in-flight persist (e.g. before Send packages `liveDraft`).
    @MainActor
    private func awaitPersistIdle() async {
        autosaveTask?.cancel()
        autosaveTask = nil
        if let persistTask { await persistTask.value }
    }

    /// One save attempt against current fields. Call only via `enqueuePersist`
    /// so overlapping runs stay serial.
    @MainActor
    private func performPersist(silent: Bool, syncAfter: Bool) async {
        // Typed-but-uncommitted addresses count too.
        for (draft, tokens) in [(toDraft, $toTokens), (ccDraft, $ccTokens), (bccDraft, $bccTokens)] {
            let cleaned = draft.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            if cleaned.contains("@"), !tokens.wrappedValue.contains(cleaned) {
                tokens.wrappedValue.append(cleaned)
            }
        }
        toDraft = ""; ccDraft = ""; bccDraft = ""
        guard hasContent else {
            draftStatus = .idle
            return
        }
        let fingerprint = contentFingerprint
        if fingerprint == lastSavedFingerprint {
            if silent { draftStatus = .saved }
            // Already on the server — still sync on dismiss so Drafts/thread UI
            // pick up a silent autosave that never called sync().
            if syncAfter, didSilentSave || liveDraft != nil {
                await store.syncDraftMailbox(fromAccountId)
            }
            return
        }
        // Show Saving… for both autosave and dismiss-path saves so offline
        // ✕/Esc doesn't look hung while URLSession waits (N2).
        draftStatus = .saving
        // Best effort on the files: an unreadable pick shouldn't lose the text.
        let attachments = (try? collectAttachments()) ?? restoredAttachments
        // Closed while the prefilled files were still downloading: their
        // chips aren't in yet, so re-fetch them before saving — otherwise
        // the re-saved draft would silently drop them.
        let pendingSources: [Message] = {
            guard loadingAttachments else { return [] }
            if let draft = liveDraft { return [draft] }
            if request.forward, let original {
                if request.forwardAll {
                    let thread = ForwardComposer.forwardableMessages(
                        store.messages(inThread: original.threadId))
                    return thread.isEmpty ? [original] : thread
                }
                return [original]
            }
            return []
        }()
        let (apiAccount, identity, to, cc, bcc, subj, body, old) =
            (fromAccountId, fromEmail,
             toTokens.joined(separator: ", "), ccTokens.joined(separator: ", "),
             bccTokens.joined(separator: ", "), subject, fullBody,
             liveDraft)
        // Like the send path, a forward's original rides along so the
        // draft keeps its HTML formatting (it won't thread the draft).
        let (reply, isForward) = (request.replyTo, request.forward)
        var atts = attachments
        for source in pendingSources {
            atts = ((try? await store.loadAttachments(for: source)) ?? []) + atts
        }
        // Send unmounts without awaiting this task; drop a late createDraft so
        // we don't upload a draft the user already sent.
        if didFinish { return }
        // Demo: never claim "Draft saved" — close uses non-silent for the notice.
        if store.demoMode {
            if !silent {
                _ = await store.saveDraft(from: apiAccount, fromEmail: identity,
                                          to: to, cc: cc, bcc: bcc, subject: subj,
                                          body: body, replyTo: reply, forward: isForward,
                                          attachments: atts, replacing: old,
                                          silent: false)
            }
            draftStatus = .idle
            return
        }
        let saved = await store.saveDraft(from: apiAccount, fromEmail: identity,
                                          to: to, cc: cc, bcc: bcc, subject: subj,
                                          body: body, replyTo: reply, forward: isForward,
                                          attachments: atts, replacing: old,
                                          silent: silent,
                                          syncAfter: syncAfter)
        if let saved {
            // createDraft was already on the wire when Send cancelled the task:
            // delete the just-created draft so Gmail Drafts doesn't keep sent
            // content (PendingSend.replacingDraft is the older completed id).
            if didFinish {
                await store.deleteUnderlyingDraft(saved, silent: true)
                return
            }
            replacingDraft = saved
            // Autosave moved the draft to a new id — keep the card hidden.
            // Only claim while *this* request is still the open compose; a
            // fire-and-forget save after onDisappear must not resurrect a
            // dead requestId (Fable M1).
            if store.composeRequest?.id == request.id {
                store.noteComposingDraft(saved.id, requestId: request.id)
            }
            lastSavedFingerprint = fingerprint
            if silent { didSilentSave = true }
            draftStatus = .saved
            // Content may have changed during the network round-trip — chain
            // one more silent save so we don't leave an older body as "the"
            // draft. Only after success (failed saves must not recurse).
            if silent, !didFinish, hasContent,
               contentFingerprint != lastSavedFingerprint {
                await performPersist(silent: true, syncAfter: false)
            }
        } else {
            draftStatus = .failed
        }
    }

    /// Fire-and-forget save for unmount when another compose replaced us.
    private func saveDraftIfNeeded() {
        autosaveTask?.cancel()
        Task { @MainActor in
            await enqueuePersist(silent: false, syncAfter: true)
        }
    }

    /// Close and keep the work: unsent content becomes a real Gmail draft.
    /// Awaits the save so offline failure still surfaces via lastError, and
    /// always syncs after a silent autosave so the Drafts list is fresh.
    private func saveAndClose() {
        guard beginFinish() else { return }
        Task { @MainActor in
            await enqueuePersist(silent: false, syncAfter: true)
            close()
        }
    }

    /// Esc from ContentView while this card is expanded: dismiss compose
    /// sheets first, then the same path as the header ✕ / `.cancelAction`.
    private func handleComposeEsc() {
        if showLinkSheet { showLinkSheet = false; return }
        if showScheduleSheet { showScheduleSheet = false; return }
        if showSnippets { showSnippets = false; return }
        if showFilePicker { showFilePicker = false; return }
        if isMinimized { return }
        saveAndClose()
    }

    /// Discard without keeping a Gmail draft — deletes the live autosave chain.
    private func discardAndClose() {
        guard beginFinish() else { return }
        Task { @MainActor in
            // Finish any in-flight createDraft so we delete the real server draft.
            await awaitPersistIdle()
            if let draft = liveDraft {
                await store.deleteUnderlyingDraft(draft)
            }
            close()
        }
    }

    /// Everything attached right now, data loaded: chips carried in from a
    /// forward/undo/draft plus files picked in this session.
    private func collectAttachments() throws -> [MIMEBuilder.Attachment] {
        var attachments = restoredAttachments
        for url in attachmentURLs {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            attachments.append(.init(filename: url.lastPathComponent, mimeType: mime, data: data))
        }
        return attachments
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isMinimized {
                minimizedBar
            } else {
                expandedHeader
                expandedBody
            }
        }
        .padding(isMinimized ? EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 8)
                             : EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
        .accessibilityIdentifier(isSplit ? "composeSplit"
                                 : isInline ? "composeInline" : "composeCard")
        .onAppear {
            store.composeMinimized = false
            isMinimized = false
            // Seed the replace chain before prefill so undo-send restores any
            // draft that Send was about to delete.
            replacingDraft = editingDraft ?? request.restore?.replacingDraft
            // Hide this draft's in-thread card while its editor is open.
            store.noteComposingDraft(editingDraft?.id, requestId: request.id)
            store.noteComposingDraft(replacingDraft?.id, requestId: request.id)
            prefill()
            // Prefill mutates fields — re-baseline carefully.
            // restore MUST win over editDraft: cancelPendingSend often sets
            // both (editDraft = the autosaved chain). The server draft only
            // has the last-autosaved body; anything typed in the ≤1.5s before
            // Send lives only in restore.body. Treating that as clean loses
            // the tail on Esc (H4 residual).
            if request.restore != nil {
                lastSavedFingerprint = ""
                draftStatus = .idle
            } else if editingDraft != nil {
                // Reopened draft is already on the server.
                lastSavedFingerprint = contentFingerprint
                draftStatus = .saved
            } else {
                // New/reply prefill — baseline so pure quote isn't autosaved.
                lastSavedFingerprint = contentFingerprint
                draftStatus = .idle
            }
            installSlashKeyMonitor()
            store.slashPickerVisible = slashActive
            suggestRepliesIfEligible()
        }
        .onDisappear {
            // Unmounted without an explicit exit: a new compose/reply request
            // replaced this card (single-key shortcuts allow that while
            // minimized). Keep the work as a draft instead of dropping it.
            if !didFinish { saveDraftIfNeeded() }
            // Release the draft-card hide keyed to *this* request only; a newer
            // card that already appeared keeps its own claim.
            store.endComposingDrafts(requestId: request.id)
            store.composeMinimized = false
            store.slashPickerVisible = false
            autosaveTask?.cancel()
            suggestionsTask?.cancel()
            if let monitor = slashKeyMonitor {
                NSEvent.removeMonitor(monitor)
                slashKeyMonitor = nil
            }
        }
        // Publish `/` picker visibility for ContentView's Esc ladder (explicit
        // gate — local monitors fire FIFO and must not rely on order).
        .onChange(of: slashActive) { store.slashPickerVisible = slashActive }
        // Minimize keeps the card mounted (no onDisappear) — stop a live
        // suggestion stream instead of paying for chips nobody can see.
        .onChange(of: isMinimized) { _, minimized in
            guard minimized, suggestionsLoading else { return }
            suggestionsGeneration &+= 1
            suggestionsTask?.cancel()
            suggestionsLoading = false
            suggestedReplies = []
        }
        .onChange(of: store.slashPickerDismissToken) {
            slashDismissed = true
            store.slashPickerVisible = false
        }
        // ContentView Esc while expanded compose has NSText focus (close button
        // `.cancelAction` does not fire then). Sheets first, then save & close.
        .onChange(of: store.composeEscToken) { handleComposeEsc() }
        .onChange(of: body_) { scheduleAutosave() }
        .onChange(of: subject) { scheduleAutosave() }
        .onChange(of: toTokens) { scheduleAutosave() }
        .onChange(of: ccTokens) { scheduleAutosave() }
        .onChange(of: bccTokens) { scheduleAutosave() }
        .onChange(of: attachmentURLs) { scheduleAutosave() }
        // Dropped files land in restoredAttachments; chip removal must also
        // dirty the draft so a discarded drop doesn't reappear after restart.
        .onChange(of: restoredAttachments.map(\.filename).joined(separator: "|")) {
            scheduleAutosave()
        }
        .onChange(of: store.accounts) {
            // Accounts can finish loading after the card appears — backfill From.
            if fromEmail.isEmpty { ensureFromSelection() }
        }
        .onChange(of: store.sendIdentities) {
            // Send-as aliases arrive after first sync — re-scope the menu.
            // Prefer current selection, then a sticky draft/restore From, then
            // the mailbox default (never silently replace a draft's send-as
            // with the primary just because identities loaded late).
            ensureFromSelection(preferCurrent: true)
        }
        .sheet(isPresented: $showScheduleSheet) {
            // Same natural-language picker as snooze (type "tomorrow 9am"),
            // with send-time presets. Past dates are filtered out.
            DatePickSheet(
                placeholder: "Send when? — try \"tomorrow 9am\", \"mon\", \"aug 12\"",
                presets: SendSchedule.allCases.map { .init(title: $0.title, date: $0.date()) },
                footnote: "Scheduled mail sends while MishMail is open",
                minDate: Date()
            ) { date in
                if let date { scheduleSend(at: date) }
            }
        }
        .sheet(isPresented: $showLinkSheet) {
            ComposeLinkSheet(
                initialText: linkInitialText,
                initialURL: linkInitialURL,
                isEditing: linkIsEditing,
                onApply: { text, url in applyLink(text: text, url: url) },
                onRemove: { removeLinkAtSelection() }
            )
        }
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { appendAttachmentURLs(urls) }
        }
        // Card chrome (header/footer/padding) also accepts file drops — body
        // NSTextView handles its own via ComposeBodyTextView so paths never
        // land as typed text.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            ComposeAttachmentDrop.fileURLs(from: providers) { urls in
                ingestDroppedFiles(urls)
            }
            // Claim the drop if any provider looks like a file; load is async.
            return providers.contains {
                $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            }
        }
    }

    /// Merge picked files into the chip list (path-deduped). Open-panel
    /// URLs keep their powerbox grant for later `collectAttachments`.
    private func appendAttachmentURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        attachmentURLs = ComposeAttachmentDrop.dedupeAppend(existing: attachmentURLs,
                                                            incoming: urls)
    }

    /// Finder / inter-app drops: sandbox grants are transient, so load bytes
    /// now into `restoredAttachments` (same chip path as forward/undo) rather
    /// than holding bare URLs that may fail at send/autosave. Reads off the
    /// main actor so a large video drop doesn't stall the UI.
    private func ingestDroppedFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let attempted = urls.count
        // Detached: ComposeView is MainActor; don't inherit it for the reads.
        Task.detached { [urls] in
            var loaded: [MIMEBuilder.Attachment] = []
            var failed = 0
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    failed += 1
                    continue
                }
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                    ?? "application/octet-stream"
                loaded.append(.init(filename: url.lastPathComponent, mimeType: mime, data: data))
            }
            let loadedSnapshot = loaded
            let failedSnapshot = failed
            await MainActor.run {
                let existingNames = Set(restoredAttachments.map(\.filename)
                    + attachmentURLs.map(\.lastPathComponent))
                let merge = ComposeAttachmentDrop.mergeNewFilenames(
                    existing: existingNames,
                    incoming: loadedSnapshot.map(\.filename),
                    failedReads: failedSnapshot)
                // First occurrence of each new name wins (loaded order preserved).
                var pending = Set(merge.added)
                for att in loadedSnapshot where pending.contains(att.filename) {
                    restoredAttachments.append(att)
                    pending.remove(att.filename)
                }
                // dropStatusMessage is nil only for a fully clean add.
                if let msg = ComposeAttachmentDrop.dropStatusMessage(merge: merge,
                                                                     attempted: attempted) {
                    error = msg
                }
                if !merge.added.isEmpty {
                    scheduleAutosave()
                }
            }
        }
    }

    // MARK: - Header / minimize chrome

    /// Collapsed strip: click anywhere (except ×) to restore the full card.
    private var minimizedBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(headerTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                setMinimized(false)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Expand compose")
            closeButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { setMinimized(false) }
        .help("Expand compose")
    }

    /// Expanded title bar: click chrome (title / empty space) to minimize,
    /// like Notion Mail. Inline replies skip minimize (Pop out instead) so the
    /// reading pane stays usable. Buttons still own their own hits.
    private var expandedHeader: some View {
        HStack(spacing: 6) {
            Text(headerTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            // Side by side: the source conversation fills the left half while
            // the draft takes the right (⇧⌘↩). Needs a reply/forward parent.
            if original != nil {
                Button {
                    store.toggleSplitCompose()
                } label: {
                    Image(systemName: isSplit
                          ? "arrow.down.right.and.arrow.up.left"
                          : "rectangle.split.2x1")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Esc ladder lives in ContentView via ComposeEsc (works while
                // NSText has focus). Shortcut is a backup when focus is elsewhere.
                .keyboardShortcut(isSplit ? .cancelAction : nil)
                .help(isSplit ? "Exit side by side (esc or ⇧⌘↩)"
                              : "View side by side with the conversation (⇧⌘↩)")
            }
            if isSplit {
                // Split owns the full window; exit is the button above.
            } else if isInline {
                Button {
                    store.popOutCompose()
                } label: {
                    Image(systemName: "arrow.up.forward.and.arrow.down.backward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Pop out to floating compose")
            } else {
                Button {
                    setMinimized(true)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Minimize")
            }
            closeButton
        }
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isInline && !isSplit { setMinimized(true) }
        }
        .help(isInline || isSplit ? "Reply" : "Minimize compose")
    }

    @ViewBuilder
    private var closeButton: some View {
        // Esc closes only while expanded — minimized compose yields Esc to the
        // mailbox (reading-pane / multi-select ladder in ContentView), and
        // split yields it to the exit-split button (see expandedHeader).
        if isMinimized || isSplit {
            Button(action: saveAndClose) {
                closeGlyph
            }
            .buttonStyle(.plain)
            .help(hasContent ? "Save draft & close" : "Close")
        } else {
            Button(action: saveAndClose) {
                closeGlyph
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(hasContent ? "Save draft & close" : "Close")
        }
    }

    @ViewBuilder
    private var draftStatusLabel: some View {
        // Always reserve the longest status width so idle → "Draft saved"
        // does not insert space into the footer (that reflow grew the card
        // chrome slightly and used to wrap "Snippets"). Hidden sizer keeps
        // layout; painted text is trailing-aligned so it sits next to trash
        // (which stays glued to Send — see right-cluster order).
        ZStack(alignment: .trailing) {
            Text(ComposeDraftStatusLayout.widthSizerLabel)
                .font(.system(size: ComposeDraftStatusLayout.fontSize))
                .lineLimit(1)
                .hidden()
                .accessibilityHidden(true)

            switch draftStatus {
            case .idle:
                EmptyView()
            case .saving:
                Text(ComposeDraftStatusLayout.savingLabel)
                    .font(.system(size: ComposeDraftStatusLayout.fontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("draftStatusSaving")
            case .saved:
                Text(ComposeDraftStatusLayout.savedLabel)
                    .font(.system(size: ComposeDraftStatusLayout.fontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("draftStatusSaved")
            case .failed:
                Text(ComposeDraftStatusLayout.failedLabel)
                    .font(.system(size: ComposeDraftStatusLayout.fontSize))
                    .foregroundStyle(.red.opacity(0.85))
                    .lineLimit(1)
                    .accessibilityIdentifier("draftStatusFailed")
            }
        }
        .frame(height: ComposeDraftStatusLayout.rowHeight)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var closeGlyph: some View {
        Image(systemName: "xmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Reply/forward context. Forwards always start a new Gmail
            // conversation (gmail.com / Notion Mail); say so so users don't
            // expect the Kearney-style source thread to absorb the send.
            if let original {
                HStack(spacing: 5) {
                    Image(systemName: request.forward ? "arrowshape.turn.up.right" : "arrowshape.turn.up.left")
                        .font(.system(size: 10))
                    Text(forwardContextLabel(from: original))
                        .font(.system(size: 11))
                        .lineLimit(2)
                }
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            }

            // From row — laid out like the address rows (30pt label gutter)
            // so the identity text lines up with the To/Cc/Bcc fields.
            // Reply/forward/draft: only identities for the message's mailbox
            // (primary + Gmail send-as). Never other OAuth accounts — their
            // threadIds are not valid on this mailbox.
            HStack(alignment: .center, spacing: 6) {
                Text("From")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .leading)
                Menu {
                    ForEach(availableFromIdentities) { identity in
                        Button(menuTitle(identity)) { selectFrom(identity) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(fromEmail.isEmpty ? "Select account" : fromEmail)
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                // .button + .plain renders custom labels reliably on macOS
                // (borderlessButton can drop the label text entirely).
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                // Hide the chevron when there's only one choice (common on reply).
                .disabled(availableFromIdentities.count <= 1)
                Spacer()
            }
            .padding(.vertical, 7)
            Divider()

            TokenAddressField(label: "To", tokens: $toTokens, draft: $toDraft,
                              // New mail and forwards start with no recipients,
                              // so typing lands in To. A restored (undone) send
                              // has recipients — the body keeps focus there.
                              autoFocus: request.restore == nil
                                  && (request.forward
                                      || (original == nil && editingDraft == nil)))
                .overlay(alignment: .trailing) {
                    // Cc/Bcc live on the To row, Gmail-style.
                    HStack(spacing: 8) {
                        // Either button reveals both fields — Ron expects
                        // Cc/Bcc to open together.
                        if !showCc {
                            Button("Cc") { showCc = true; showBcc = true }
                                .buttonStyle(.plain)
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        if !showBcc {
                            Button("Bcc") { showCc = true; showBcc = true }
                                .buttonStyle(.plain)
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 8)
                    .background(Color(nsColor: .windowBackgroundColor))
                }
                .zIndex(3)
            if showCc || !ccTokens.isEmpty {
                TokenAddressField(label: "Cc", tokens: $ccTokens, draft: $ccDraft)
                    .zIndex(2)
            }
            if showBcc || !bccTokens.isEmpty {
                TokenAddressField(label: "Bcc", tokens: $bccTokens, draft: $bccDraft)
                    .zIndex(1)
            }

            // AppKit field so we can set baseWritingDirection (SwiftUI
            // TextField only gets alignment, which still shreds mixed subjects).
            ComposeSubjectField(text: $subject)
                .frame(height: 22)
                .padding(.vertical, 8)
            Divider()

            // Markdown source editor: live highlight + ⌘B/⌘I/… shortcuts.
            // ghostText: Gmail-style "Hi {name}," grey suffix at the start of
            // a thread; Tab (via slashKeyMonitor) commits it into the body.
            ComposeBodyEditor(text: $body_, isFocused: $bodyFocused,
                              caretUTF16: $bodyCaretUTF16,
                              selection: $bodySelection,
                              ghostText: greetingGhostText,
                              formatTarget: formatTarget, fontSize: 14,
                              onFilesDropped: { ingestDroppedFiles($0) })
                .padding(.top, 10)
                .padding(.bottom, 6)
                // Grow with authored content while the quote is collapsed so
                // short replies don't scroll under the "…" pill; see
                // bodyEditorMaxHeight / bodyEditorMinHeight.
                .frame(minHeight: bodyEditorMinHeight, maxHeight: bodyEditorMaxHeight)
                .onChange(of: body_) {
                    syncSlashSelection()
                    if slashToken == nil { slashDismissed = false }
                    // Typing makes the suggestions stale — stop paying for
                    // them, and drop any half-streamed chips so deleting back
                    // to empty never presents a truncated set as finished.
                    if suggestionsLoading, !authoredHeadIsEmpty {
                        suggestionsGeneration &+= 1
                        suggestionsTask?.cancel()
                        suggestionsLoading = false
                        suggestedReplies = []
                    }
                }
                .onChange(of: bodyCaretUTF16) {
                    syncSlashSelection()
                    if slashToken == nil { slashDismissed = false }
                }
                .onChange(of: fromAccountId) {
                    syncSlashSelection()
                }
                .onChange(of: store.allSnippets) {
                    // Delete/edit in Settings while the picker is open.
                    syncSlashSelection()
                }

            // The `/` picker renders directly under the editor, where the
            // cursor is, so it reads as results for what you're typing.
            // layoutPriority keeps it above the quote-area Spacer when the
            // fixed-height inline reply card is short.
            if slashActive {
                SlashSnippetPicker(snippets: slashMatches,
                                   query: slashToken?.query ?? "",
                                   selectionId: slashSelectionId,
                                   choose: { insertSlashSnippet($0) })
                    .padding(.top, 4)
                    .layoutPriority(1)
                    .transition(.opacity)
            }

            // Suggested replies live here — in the compose card, right under
            // where the reply is written — so the chips clearly target this
            // draft. Hidden the moment the user types (they'd be stale).
            if suggestionsStripVisible {
                SuggestedRepliesStrip(
                    suggestions: suggestedReplies,
                    loading: suggestionsLoading,
                    modelName: suggestionsModelName,
                    error: suggestionsError,
                    pick: { insertSuggestedReply($0) },
                    regenerate: { suggestReplies() },
                    dismiss: {
                        suggestionsGeneration &+= 1
                        suggestionsTask?.cancel()
                        suggestionsLoading = false
                        withAnimation(.spring(duration: 0.25, bounce: 0)) {
                            suggestionsDismissed = true
                        }
                    })
                .padding(.bottom, 8)
                .transition(.opacity)
            }

            // The quoted original stays collapsed behind this pill (Gmail's
            // "…"). Clicking inlines it into the editor for viewing/editing.
            if !quotedTail.isEmpty {
                Button {
                    expandQuote()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(request.forward ? "Show forwarded message" : "Show quoted text")
                .padding(.bottom, 8)
            } else if quoteStartInBody != nil {
                // The quote has been inlined; let the user tuck it back
                // behind the "…" pill (Gmail's collapse control).
                Button {
                    collapseQuote()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(request.forward ? "Hide forwarded message" : "Hide quoted text")
                .padding(.bottom, 8)
            }

            // Leftover card space goes below the pill (or the editor when
            // there is no quote) so the pill hugs the last text line and
            // the footer stays pinned at the bottom — including plain new
            // mail with a short body. Expanding Spacer would eat the
            // picker's list height inside a fixed card; only fill when `/`
            // is idle.
            if !slashActive {
                Spacer(minLength: 0)
            }

            if !attachmentURLs.isEmpty || !restoredAttachments.isEmpty || loadingAttachments {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        if loadingAttachments {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini)
                                Text("Loading attachments…").font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                        }
                        ForEach(Array(restoredAttachments.enumerated()), id: \.offset) { idx, att in
                            HStack(spacing: 4) {
                                Image(systemName: "paperclip").font(.caption)
                                Text(att.filename).font(.caption)
                                Button {
                                    restoredAttachments.remove(at: idx)
                                } label: { Image(systemName: "xmark.circle.fill").font(.caption2) }
                                    .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                        ForEach(attachmentURLs, id: \.self) { url in
                            HStack(spacing: 4) {
                                Image(systemName: "paperclip").font(.caption)
                                Text(url.lastPathComponent).font(.caption)
                                Button {
                                    attachmentURLs.removeAll { $0 == url }
                                } label: { Image(systemName: "xmark.circle.fill").font(.caption2) }
                                    .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                    }
                }
                .padding(.bottom, 6)
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                    .padding(.bottom, 4)
            }

            // Snippets live in an inline panel, not a popover — always
            // visible where you write, reliable inside the docked card.
            if showSnippets {
                SnippetsPanel(insert: { snippet in
                    insertSnippet(snippet)
                    withAnimation(.easeOut(duration: 0.12)) { showSnippets = false }
                }, saveDraftAsSnippet: {
                    saveCurrentAsSnippet()
                }, close: {
                    withAnimation(.easeOut(duration: 0.12)) { showSnippets = false }
                }, accountId: fromAccountId)
                .environment(store)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Priority split: right cluster (draft status + trash + Send) is
            // fixedSize so it never clips under the card's topLeading frame;
            // left tools (attach / snippets / format) take only the remainder
            // and may clip when the card is tight. A single HStack of fixedSize
            // children used to overflow and cut "Saving…" mid-word + Send.
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    if composeToolVisible(.attach) {
                        footerButton(ComposeToolbarItem.attach) { showFilePicker = true }
                    }

                    if composeToolVisible(.link) {
                        // Slightly roomier cell than the format strip so the
                        // chain glyph isn't clipped on its left bearing.
                        footerButton(ComposeToolbarItem.link) { openLinkSheet() }
                    }

                    if composeToolVisible(.snippets) {
                        Button {
                            withAnimation(.easeOut(duration: 0.12)) { showSnippets.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: ComposeToolbarItem.snippets.systemImage)
                                Text("Snippets")
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(showSnippets ? Color.notionAccent : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        // Same as Send: never wrap/compress when "Draft saved" appears.
                        .fixedSize()
                        .keyboardShortcut("/", modifiers: .command)
                        .help(ComposeToolbarItem.snippets.help)
                        .accessibilityLabel(ComposeToolbarItem.snippets.title)
                    } else {
                        // Keep ⌘/ even when the button is hidden (Settings only
                        // hides chrome; slash insert and the panel still work).
                        Button {
                            withAnimation(.easeOut(duration: 0.12)) { showSnippets.toggle() }
                        } label: { EmptyView() }
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                        .keyboardShortcut("/", modifiers: .command)
                    }

                    // Available for replies, forwards, and new mail — the draft is
                    // generated locally and streamed into the body.
                    if composeToolVisible(.ai) {
                        footerButton(
                            drafting ? "hourglass" : ComposeToolbarItem.ai.systemImage,
                            help: ComposeToolbarItem.ai.help,
                            label: ComposeToolbarItem.ai.title
                        ) { draftWithAI() }
                            .disabled(drafting)

                        Menu {
                            Button("Rewrite") {
                                inlineEdit(.rewrite)
                            }
                            Button("Shorten") {
                                inlineEdit(.shorten)
                            }
                            Menu("Change tone") {
                                Button("Friendly") {
                                    inlineEdit(.changeTone, tone: "Friendly")
                                }
                                Button("Formal") {
                                    inlineEdit(.changeTone, tone: "Formal")
                                }
                                Button("Direct") {
                                    inlineEdit(.changeTone, tone: "Direct")
                                }
                            }
                        } label: {
                            Image(systemName: aiEditSystemImage)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 22)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Edit selection with AI")
                        .accessibilityLabel("AI edit")
                        .accessibilityIdentifier("compose.aiEdit")
                        .disabled(drafting || bodySelection.length == 0)
                    }

                    // Markdown format strip (bold/italic/headers/math…). Link is
                    // only the dedicated button above (⌘K sheet) — not duplicated
                    // at the trailing edge where clipping used to bite.
                    if ComposeToolbarItem.formatOrder.contains(where: {
                        ComposeToolbarVisibility.isVisible($0, hiddenRaw: composeToolbarHidden)
                    }) {
                        ComposeFormatBar(action: { action in
                            if action == .link { openLinkSheet() }
                            else { formatTarget.run(action) }
                        }, hiddenRaw: composeToolbarHidden)
                        .padding(.leading, 2)
                    }
                }
                // minWidth 0 lets the left cluster shrink below its ideal so the
                // right cluster keeps Send + status fully visible; clip hides
                // overflow format icons rather than pushing Send off-card.
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                // Visual clip only (SwiftUI .clipped does not block hit tests).
                // Right cluster is drawn later so Send still wins overlapping hits.
                .clipped()
                .layoutPriority(0)

                // Order: reserved status | trash | Send. Status width stays
                // reserved (no idle→saved reflow) but sits *left* of trash so
                // trash stays glued to Send — status-between-them left a large
                // empty hole when idle (screenshot).
                HStack(spacing: 10) {
                    // Notion-style draft status — dismiss is the header ✕
                    // (and Esc). Slot always sized; paint only after typing.
                    draftStatusLabel
                        .padding(.horizontal, 4)

                    Button {
                        // Discard: delete the live autosave chain (not only editDraft).
                        discardAndClose()
                    } label: {
                        Image(systemName: "trash").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(liveDraft != nil ? "Discard (deletes this draft)" : "Discard without saving")

                    // Split send button: Send now | schedule menu. Drawn by hand
                    // so both halves match; the presets are a native menu (a
                    // popover can fail to present from the docked card's edge).
                    HStack(spacing: 1) {
                        Button {
                            send()
                        } label: {
                            Text("Send")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .frame(height: ComposeDraftStatusLayout.rowHeight)
                                .background(UnevenRoundedRectangle(
                                    topLeadingRadius: 6, bottomLeadingRadius: 6,
                                    bottomTrailingRadius: 0, topTrailingRadius: 0)
                                    .fill(Color.notionAccent))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(didFinish)
                        // Never compress to "Se…" when the footer gets crowded.
                        .fixedSize()
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Send (10s undo window)")

                        // Opens the same natural-language picker as snooze —
                        // presets plus "type a date" — instead of a menu.
                        Button {
                            showScheduleSheet = true
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .frame(height: ComposeDraftStatusLayout.rowHeight)
                                .background(UnevenRoundedRectangle(
                                    topLeadingRadius: 0, bottomLeadingRadius: 0,
                                    bottomTrailingRadius: 6, topTrailingRadius: 6)
                                    .fill(Color.notionAccent))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                        .help("Schedule send")
                    }
                    .opacity(cannotSend ? 0.5 : 1)
                    .disabled(cannotSend)
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            }
            .padding(.top, 8)
        }
        // Lock the whole form while Send/discard awaits persist so keys aren't
        // typed into a finishing draft (and so the card reads as non-interactive).
        .disabled(didFinish)
    }

    private var cannotSend: Bool {
        fromEmail.isEmpty || fromAccountId.isEmpty
            || loadingAttachments   // forwarded files still downloading
            || (toTokens.isEmpty && !toDraft.contains("@")
                && bccTokens.isEmpty && !bccDraft.contains("@"))
    }

    /// Mailbox that owns this compose session. Non-nil locks From to that
    /// mailbox's primary + send-as only (reply / forward / draft edit).
    /// Undo-restore of a brand-new message does *not* lock — the user had
    /// full From choice before Send, and undo must not shrink it.
    private var fixedMailboxAccountId: String? {
        let restore = request.restore
        let threaded = restore.map {
            $0.replyTo != nil || $0.replacingDraft != nil || $0.forward
        } ?? false
        return SendIdentityResolver.fixedMailboxAccountId(
            restoreAccountId: restore?.accountId,
            restoreIsThreaded: threaded,
            draftAccountId: editingDraft?.accountId,
            originalAccountId: original?.accountId)
    }

    /// From address we must re-apply when send-as identities load late
    /// (draft header or restored pending send). Empty when none.
    private var stickyFromEmail: String {
        if let r = request.restore { return r.effectiveFromEmail }
        if let draft = editingDraft {
            return MessageParser.emailAddress(draft.fromHeader)
        }
        return ""
    }

    private var availableFromIdentities: [SendIdentity] {
        store.fromIdentities(forMailbox: fixedMailboxAccountId)
    }

    private func menuTitle(_ identity: SendIdentity) -> String {
        SendIdentityResolver.menuTitle(identity, all: store.sendIdentities.isEmpty
            ? availableFromIdentities : store.sendIdentities)
    }

    private func selectFrom(_ identity: SendIdentity) {
        fromEmail = identity.email
        fromAccountId = identity.accountId
    }

    /// Pick a valid From identity for the current mode. When
    /// `preferCurrent` is true, keep the selection if it still appears in
    /// the available list (send-as refresh shouldn't clobber a user pick).
    /// Sticky draft/restore From wins over the mailbox primary so a late
    /// identity load doesn't rewrite a send-as draft to the primary.
    private func ensureFromSelection(preferCurrent: Bool = false) {
        let options = availableFromIdentities
        if preferCurrent,
           let keep = options.first(where: {
               $0.email.caseInsensitiveCompare(fromEmail) == .orderedSame
                   && (fromAccountId.isEmpty
                       || $0.accountId.caseInsensitiveCompare(fromAccountId) == .orderedSame)
           }) {
            selectFrom(keep)
            return
        }
        // Draft / restore From may have been set optimistically before send-as
        // aliases were known — match it now that the list is complete.
        let sticky = stickyFromEmail
        if !sticky.isEmpty,
           let match = options.first(where: {
               $0.email.caseInsensitiveCompare(sticky) == .orderedSame
           }) {
            selectFrom(match)
            return
        }
        if let mailbox = fixedMailboxAccountId,
           let preferred = SendIdentityResolver.preferred(
            store.sendIdentities.isEmpty ? options : store.sendIdentities,
            in: mailbox) {
            selectFrom(preferred)
            return
        }
        // New compose: active account's preferred identity, else first option.
        if let active = store.activeAccountId,
           let preferred = SendIdentityResolver.preferred(
            store.sendIdentities.isEmpty ? options : store.sendIdentities,
            in: active) {
            selectFrom(preferred)
            return
        }
        if let first = options.first {
            selectFrom(first)
        } else if let account = store.accounts.first {
            fromEmail = account.id
            fromAccountId = account.id
        }
    }

    private func composeToolVisible(_ item: ComposeToolbarItem) -> Bool {
        ComposeToolbarVisibility.isVisible(item, hiddenRaw: composeToolbarHidden)
    }

    private func footerButton(_ item: ComposeToolbarItem,
                              action: @escaping () -> Void) -> some View {
        footerButton(item.systemImage, help: item.help, label: item.title, action: action)
    }

    private func footerButton(_ icon: String, help: String, label: String? = nil,
                              action: @escaping () -> Void) -> some View {
        // VoiceOver label is the bare action name; hover tooltip keeps the shortcut.
        let a11y = label ?? (help.split(separator: " (").first.map(String.init) ?? help)
        return Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                // Fixed cell so the chain/paperclip glyphs aren't clipped on the
                // left bearing (the original "link button is cut off" report).
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(a11y)
    }

    private func prefill() {
        // Undone send: restore exactly what was about to go out.
        if let r = request.restore {
            fromAccountId = r.accountId
            fromEmail = r.effectiveFromEmail
            toTokens = MessageParser.splitAddresses(r.to).filter { $0.contains("@") }
            ccTokens = MessageParser.splitAddresses(r.cc).filter { $0.contains("@") }
            if !ccTokens.isEmpty { showCc = true }
            bccTokens = MessageParser.splitAddresses(r.bcc).filter { $0.contains("@") }
            if !bccTokens.isEmpty { showBcc = true }
            subject = r.subject
            setBody(r.body, caretUTF16: 0)
            restoredAttachments = r.attachments
            initialBody = ""   // an undone send always counts as content
            focusBody()
            return
        }

        // Editing an existing Gmail draft: load its fields verbatim.
        if let draft = editingDraft {
            fromAccountId = draft.accountId
            // Stick the draft's From immediately (even if send-as isn't loaded
            // yet). When identities arrive, ensureFromSelection re-matches via
            // stickyFromEmail instead of silently swapping to the primary.
            let draftFrom = MessageParser.emailAddress(draft.fromHeader)
            if !draftFrom.isEmpty {
                fromEmail = draftFrom
                if let match = store.fromIdentities(forMailbox: draft.accountId)
                    .first(where: { $0.email.caseInsensitiveCompare(draftFrom) == .orderedSame }) {
                    selectFrom(match)
                }
            } else {
                ensureFromSelection()
            }
            toTokens = MessageParser.splitAddresses(draft.toHeader)
                .map { MessageParser.emailAddress($0) }.filter { $0.contains("@") }
            ccTokens = MessageParser.splitAddresses(draft.ccHeader)
                .map { MessageParser.emailAddress($0) }.filter { $0.contains("@") }
            if !ccTokens.isEmpty { showCc = true }
            bccTokens = MessageParser.splitAddresses(draft.bccHeader)
                .map { MessageParser.emailAddress($0) }.filter { $0.contains("@") }
            if !bccTokens.isEmpty { showBcc = true }
            subject = draft.subject
            setBody(draft.bodyText, caretUTF16: 0)
            initialBody = ""   // a draft always counts as content
            // The draft's files come back as chips — re-saving keeps them.
            prefillAttachments(of: draft)
            focusBody()
            return
        }

        // Reply/forward: only identities for the mailbox that holds the
        // message. New mail: active account (or first) preferred identity.
        ensureFromSelection()
        defer {
            // Prefill (reply recipients, "Re:" subject, quote) isn't authored content.
            initialSubject = subject
            initialRecipients = toTokens + ccTokens + bccTokens
        }
        // New mail prefill: header click ("email to X") or system `mailto:`.
        if original == nil,
           request.prefillTo != nil
            || request.prefillCc != nil
            || request.prefillBcc != nil
            || request.prefillSubject != nil
            || request.prefillBody != nil {
            if let to = request.prefillTo {
                toTokens = MessageParser.splitAddresses(to)
                    .map { MessageParser.emailAddress($0) }
                    .filter { $0.contains("@") }
            }
            if let cc = request.prefillCc {
                ccTokens = MessageParser.splitAddresses(cc)
                    .map { MessageParser.emailAddress($0) }
                    .filter { $0.contains("@") }
                if !ccTokens.isEmpty { showCc = true }
            }
            if let bcc = request.prefillBcc {
                bccTokens = MessageParser.splitAddresses(bcc)
                    .map { MessageParser.emailAddress($0) }
                    .filter { $0.contains("@") }
                if !bccTokens.isEmpty { showBcc = true }
            }
            if let s = request.prefillSubject { subject = s }
            if let b = request.prefillBody {
                setBody(b, caretUTF16: 0)
                // Prefill is not author-typed dirty content for discard prompts.
                initialBody = b
            }
            focusBody()
            return
        }
        guard let original else { return }
        let ownAddresses = store.ownEmailAddresses
        let sender = MessageParser.emailAddress(original.fromHeader)

        if request.forward {
            let subj = original.subject
            subject = subj.lowercased().hasPrefix("fwd:") ? subj : "Fwd: \(subj)"
            // Gmail-style forwarded block(s) instead of "> " quoting. Kept
            // verbatim and collapsed behind the "…" button: the send path
            // recomputes this package, and an untouched one lets the send
            // carry original HTML alongside the plain text. Editor starts
            // empty (cursor at top); focus stays on To. Still a *new*
            // conversation — no threadId / In-Reply-To on send.
            let parts: [ForwardComposer.Part]
            let attachmentSources: [Message]
            if request.forwardAll {
                // Exclude DRAFT-labeled rows so unsent text never leaves the box.
                let threadMsgs = ForwardComposer.forwardableMessages(
                    store.messages(inThread: original.threadId))
                // Fall back to the single message if nothing else is left.
                let msgs = threadMsgs.isEmpty ? [original] : threadMsgs
                parts = msgs.map { ForwardComposer.Part(message: $0) }
                attachmentSources = msgs
            } else {
                parts = [ForwardComposer.Part(message: original)]
                attachmentSources = [original]
            }
            quotedTail = ForwardComposer.forwardBlock(parts: parts)
            // Forwards carry the source attachment(s) (Gmail does the same).
            // They arrive async; Send holds until they're in.
            prefillAttachments(of: attachmentSources)
            return
        } else {
            if ownAddresses.contains(sender.lowercased()) {
                // Replying to my own message: target its recipients, not me.
                toTokens = MessageParser.splitAddresses(original.toHeader)
                    .map { MessageParser.emailAddress($0) }
                    .filter { $0.contains("@") && !ownAddresses.contains($0.lowercased()) }
                if toTokens.isEmpty { toTokens = [sender] }  // genuinely a note to self
            } else {
                toTokens = [sender]
            }
            if request.replyAll {
                // Everyone on the original except me and whoever is already in To.
                let taken = Set(toTokens.map { $0.lowercased() })
                let others = MessageParser.splitAddresses(original.toHeader + "," + original.ccHeader)
                    .map { MessageParser.emailAddress($0) }
                    .filter { $0.contains("@") }
                    .filter { !ownAddresses.contains($0.lowercased())
                              && $0.lowercased() != sender.lowercased()
                              && !taken.contains($0.lowercased()) }
                var seen = Set<String>()
                ccTokens = others.filter { seen.insert($0.lowercased()).inserted }
                if !ccTokens.isEmpty { showCc = true }
            }
            let subj = original.subject
            subject = subj.lowercased().hasPrefix("re:") ? subj : "Re: \(subj)"
        }

        // Quote the previous message so the context travels with the draft —
        // collapsed behind the "…" button so the editor starts empty and the
        // cursor lands at the top. Shape must match ReplyComposer.plainQuote
        // exactly so send can upgrade to Gmail-style HTML when untouched.
        quotedTail = ReplyComposer.plainQuote(of: original)
        if let b = request.prefillBody {
            setBody(b, caretUTF16: (b as NSString).length)
            initialBody = b
        }
        // Tone once per compose — greeting ghost re-reads this on each keystroke.
        let body = MessageParser.replyQuotableText(
            text: original.bodyText, html: original.bodyHTML)
        greetingTone = GreetingAutocomplete.tone(ofPreviousBody: body)
        focusBody()
    }

    private func forwardContextLabel(from original: Message) -> String {
        if request.forward {
            let who = MessageParser.displayName(fromHeader: original.fromHeader)
            let head = request.forwardAll
                ? "Forwarding conversation"
                : "Forwarding message from \(who)"
            return "\(head) · Starts a new conversation"
        }
        return "Replying to \(MessageParser.displayName(fromHeader: original.fromHeader))"
    }

    /// Pulls attachments from one or more messages (forwarded original(s),
    /// or a draft being reopened) into the card as removable chips. They
    /// arrive async; Send holds until the download finishes, and they don't
    /// count as authored content for the save-on-close heuristic.
    private func prefillAttachments(of messages: [Message]) {
        let sources = messages.filter(\.hasAttachment)
        guard !sources.isEmpty else { return }
        loadingAttachments = true
        Task {
            var collected: [MIMEBuilder.Attachment] = []
            var lastError: String?
            for message in sources {
                do {
                    collected.append(contentsOf: try await store.loadAttachments(for: message))
                } catch {
                    lastError = error.localizedDescription
                }
            }
            await MainActor.run {
                restoredAttachments.append(contentsOf: collected)
                prefilledAttachmentNames = restoredAttachments.map(\.filename)
                // Surface partial failures too — a 5-message Forward all with
                // one bad attachment should not look like a clean success.
                if let lastError {
                    self.error = collected.isEmpty
                        ? "Couldn't load the attachments: \(lastError)"
                        : "Some attachments couldn't be loaded: \(lastError)"
                }
                loadingAttachments = false
            }
        }
    }

    private func prefillAttachments(of message: Message) {
        prefillAttachments(of: [message])
    }

    // MARK: - Suggested replies

    /// Replies only (no forwards, reopened drafts, or undo-send restores),
    /// gated on the same Settings visibility as the other AI compose tools.
    private var suggestionsEligible: Bool {
        replyTo != nil && !request.forward && editingDraft == nil
            && request.restore == nil
            && suggestRepliesEnabled
            && composeToolVisible(.ai)
    }

    private var authoredHeadIsEmpty: Bool {
        String(body_[..<authoredHeadEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var suggestionsStripVisible: Bool {
        suggestionsEligible && !suggestionsDismissed && !slashActive
            && authoredHeadIsEmpty
            && (suggestionsLoading || !suggestedReplies.isEmpty
                || suggestionsError != nil)
    }

    /// Auto-start on open for a fresh reply — the chips appear where the reply
    /// is written, so there's no separate button to find (or wait on).
    private func suggestRepliesIfEligible() {
        guard suggestionsEligible, !suggestionsRequested,
              request.prefillBody == nil, authoredHeadIsEmpty else { return }
        suggestReplies()
    }

    /// The message the chips answer: the newest inbound in the thread. Reply
    /// parents on the newest message, which can be the user's own outbound —
    /// suggesting answers to your own email is the old flow's invariant
    /// (latestInboundMessage) and it must hold here too.
    private var suggestionSourceMessage: Message? {
        guard let original else { return nil }
        let thread = store.messages(inThread: original.threadId)
        return thread.last(where: {
            !SyncEngine.isOwnOutbound($0, accountEmail: fromAccountId)
        }) ?? original
    }

    private func suggestReplies() {
        guard suggestionsEligible, let source = suggestionSourceMessage
        else { return }
        suggestionsRequested = true
        suggestionsDismissed = false
        suggestionsGeneration &+= 1
        let generation = suggestionsGeneration
        suggestionsTask?.cancel()
        suggestedReplies = []
        suggestionsError = nil
        suggestionsLoading = true
        suggestionsModelName = LLMTaskRunner.resolve(.triage)?.model

        // Thread payloads load headers + snippets only; hydrate the body the
        // way the old flow did or the prompt can be an empty context.
        let hydrated = store.messagesWithBodies(ids: [source.id]).first ?? source
        let prompt = LLMPrompts.quickReplies(
            subject: subject,
            latestFrom: source.fromHeader,
            latestBody: String(MessageParser.replyQuotableText(
                text: hydrated.bodyText, html: hydrated.bodyHTML).prefix(2_000)),
            userEmail: fromEmail)

        suggestionsTask = Task {
            var raw = ""
            var shown = 0
            do {
                for try await piece in LLMTaskRunner.stream(task: .triage,
                                                            prompt: prompt) {
                    guard !Task.isCancelled else { return }
                    raw += piece
                    // Stream chips in per completed line — the strip fills as
                    // the model writes instead of blocking on the full answer.
                    // Only a newline can complete a line; skip the parse of
                    // the whole accumulated text on every other token.
                    guard piece.contains(where: \.isNewline) else { continue }
                    let partial = LLMPrompts.parseStreamingQuickReplies(raw)
                    if partial.count > shown {
                        shown = partial.count
                        let snapshot = partial
                        await MainActor.run {
                            guard suggestionsGeneration == generation else { return }
                            suggestedReplies = snapshot
                        }
                    }
                }
                let parsed = LLMPrompts.parseQuickReplies(raw)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard suggestionsGeneration == generation else { return }
                    suggestedReplies = parsed
                    suggestionsError = parsed.isEmpty
                        ? "No replies were suggested." : nil
                    suggestionsLoading = false
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard suggestionsGeneration == generation else { return }
                    suggestionsError = LLMTaskRunner.errorMessage(
                        error, task: .triage)
                    suggestionsLoading = false
                }
            }
        }
    }

    /// The strip only shows over an empty authored head, so inserting replaces
    /// that head (any whitespace) and keeps the quote/tail untouched.
    private func insertSuggestedReply(_ text: String) {
        let tail = String(body_[authoredHeadEnd...])
        setBody(text + tail, caretUTF16: (text as NSString).length)
        withAnimation(.spring(duration: 0.25, bounce: 0)) {
            suggestionsDismissed = true
        }
        focusBody()
    }

    private func draftWithAI() {
        drafting = true
        error = nil
        // Split off any quoted original: everything above it is the "intent",
        // the quote is preserved below the streamed draft.
        let quoteStart = body_.range(of: "\n" + ForwardComposer.marker)
            ?? body_.range(of: "\nOn ")
        let quote = quoteStart.map { String(body_[$0.lowerBound...]) } ?? ""
        let intent = String(quoteStart.map { body_[..<$0.lowerBound] } ?? Substring(body_))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt: String
        if let original {
            prompt = LLMPrompts.draftReply(
                originalFrom: original.fromHeader,
                originalBody: MessageParser.replyQuotableText(
                    text: original.bodyText, html: original.bodyHTML),
                intent: intent,
                userEmail: fromEmail)
        } else {
            prompt = LLMPrompts.draftNew(intent: intent, userEmail: fromEmail)
        }
        let quoteTail = quote.isEmpty ? "" : "\n" + quote
        Task {
            do {
                // Stream tokens in as the local model produces them.
                var accumulated = ""
                for try await piece in LLMTaskRunner.stream(task: .drafts, prompt: prompt) {
                    accumulated += piece
                    let snapshot = accumulated
                    await MainActor.run {
                        // Caret follows the growing draft (end of authored head).
                        setBody(snapshot + quoteTail,
                                caretUTF16: (snapshot as NSString).length)
                    }
                }
            } catch {
                await MainActor.run {
                    self.error = LLMTaskRunner.errorMessage(error, task: .drafts)
                }
            }
            await MainActor.run { drafting = false }
        }
    }

    /// The current body selection, preferring the live editor over the last
    /// coordinator-published snapshot because a toolbar/menu click can move
    /// first responder before its selection callback is delivered.
    private func currentBodySelection() -> NSRange? {
        let nsBody = body_ as NSString
        var selection = bodySelection
        if let textView = NSApp.keyWindow?.firstResponder as? ComposeBodyTextView {
            selection = textView.selectedRange()
        }
        guard selection.location != NSNotFound,
              selection.location >= 0,
              selection.location <= nsBody.length else { return nil }
        selection.length = min(max(selection.length, 0),
                               nsBody.length - selection.location)
        guard selection.length > 0 else { return nil }
        return selection
    }

    /// Replace the selected text, then stream the replacement into the same
    /// anchor. The prefix/suffix snapshot mirrors draftWithAI's accumulated
    /// streaming writes while allowing an arbitrary insertion point.
    private func inlineEdit(_ edit: LLMPrompts.InlineEdit, tone: String? = nil) {
        guard !drafting, let selection = currentBodySelection() else { return }
        let source = body_ as NSString
        let selectedText = source.substring(with: selection)
        let prompt = LLMPrompts.inlineEdit(edit, selection: selectedText, tone: tone)
        let prefix = source.substring(to: selection.location)
        let suffix = source.substring(from: selection.location + selection.length)
        let insertionLocation = selection.location
        let originalBody = prefix + selectedText + suffix
        let originalCaret = insertionLocation + (selectedText as NSString).length

        setBody(prefix + suffix, caretUTF16: insertionLocation)
        bodyFocused = true
        drafting = true
        error = nil

        Task {
            var accumulated = ""
            do {
                for try await piece in LLMTaskRunner.stream(task: .drafts, prompt: prompt) {
                    accumulated += piece
                    let snapshot = accumulated
                    await MainActor.run {
                        setBody(prefix + snapshot + suffix,
                                caretUTF16: insertionLocation + (snapshot as NSString).length)
                    }
                }
                if accumulated.isEmpty {
                    await MainActor.run {
                        // Empty successful streams are failures too: do not
                        // leave the user's selection deleted without undo.
                        setBody(originalBody, caretUTF16: originalCaret)
                        self.error = "The model returned no replacement."
                    }
                }
            } catch {
                await MainActor.run {
                    if accumulated.isEmpty {
                        // Restore before presenting the provider error. Partial
                        // replacements remain intact when a later token fails.
                        setBody(originalBody, caretUTF16: originalCaret)
                    }
                    self.error = LLMTaskRunner.errorMessage(error, task: .drafts)
                }
            }
            await MainActor.run { drafting = false }
        }
    }

    private var aiEditSystemImage: String {
        NSImage(systemSymbolName: "wand.and.sparkles", accessibilityDescription: nil) != nil
            ? "wand.and.sparkles"
            : "character.cursor.ibeam"
    }

    /// Where the quoted original starts (reply/forward), or the end of the
    /// body. Slash triggers only count in the part the user writes in.
    private var authoredHeadEnd: String.Index {
        (body_.range(of: "\n" + ForwardComposer.marker)
            ?? body_.range(of: #"\n+On .+ wrote:\n"#, options: .regularExpression))?
            .lowerBound ?? body_.endIndex
    }

    /// The active `/query` ending at the caret inside the authored head.
    /// Caret-based so a second `/` mid-message (or after a prior insert) works
    /// and so inserting never swallows text that sits after the caret.
    /// Returns nil when the caret sits past the head (e.g. inside an expanded
    /// quote) — clamping would falsely keep a head token live.
    private var slashToken: SnippetInsertion.SlashToken? {
        let head = String(body_[..<authoredHeadEnd])
        let headUTF16 = (head as NSString).length
        guard bodyCaretUTF16 >= 0, bodyCaretUTF16 <= headUTF16 else { return nil }
        return SnippetInsertion.slashToken(in: head, caretUTF16: bodyCaretUTF16)
    }

    /// First To recipient's first name for greeting autocomplete.
    ///
    /// On reply, prefers the From display name of the message being replied to
    /// (the last sender) when To matches that address — so we greet "John" even
    /// when contacts only know the bare email. Role mailboxes (Backoffice,
    /// Support, noreply) yield no suggestion rather than "Hi Backoffice,".
    private var greetingRecipientFirstName: String {
        let token = toTokens.first
            ?? (toDraft.contains("@")
                ? toDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil)
        guard let token, !token.isEmpty else { return "" }
        let (_, email) = GreetingAutocomplete.person(from: token)
        let emailKey = email.lowercased()
        let contactName = store.contacts.first(where: {
            $0.email.caseInsensitiveCompare(emailKey) == .orderedSame
        })?.name
        // Last sender's From display — only when it is this To recipient.
        var headerName: String?
        if let original {
            let fromEmail = MessageParser.emailAddress(original.fromHeader).lowercased()
            if fromEmail == emailKey {
                headerName = MessageParser.displayName(fromHeader: original.fromHeader)
            }
        }
        return GreetingAutocomplete.recipientFirstName(
            token: token, contactName: contactName, headerName: headerName)
    }

    /// Live Hi/Hey/Hello ghost at the start of a thread. Hidden while the
    /// `/` picker owns the body or the body isn't focused.
    private var greetingSuggestion: GreetingAutocomplete.Suggestion? {
        guard bodyFocused, !slashActive else { return nil }
        let head = String(body_[..<authoredHeadEnd])
        let headUTF16 = (head as NSString).length
        // Same trap as slashToken: bodyCaretUTF16 is full-body. A caret inside
        // an expanded quote is > headUTF16 — never clamp it back to the head
        // or ghost/Tab fire mid-quote.
        guard bodyCaretUTF16 >= 0, bodyCaretUTF16 <= headUTF16 else { return nil }
        return GreetingAutocomplete.suggestion(
            authoredBody: head,
            caretUTF16: bodyCaretUTF16,
            firstName: greetingRecipientFirstName,
            tone: greetingTone)
    }

    /// Grey suffix passed into the body editor (empty when no suggestion).
    private var greetingGhostText: String {
        greetingSuggestion?.ghost ?? ""
    }

    /// Tab accept for the greeting ghost. Returns true when it handled Tab.
    @discardableResult
    private func acceptGreetingSuggestion() -> Bool {
        guard let suggestion = greetingSuggestion else { return false }
        let head = String(body_[..<authoredHeadEnd])
        let headUTF16 = (head as NSString).length
        let result = GreetingAutocomplete.applying(
            suggestion, toBody: body_, authoredHeadEndUTF16: headUTF16)
        setBody(result.body, caretUTF16: result.caretUTF16)
        bodyFocused = true
        return true
    }

    /// Whether the `/` picker should be showing: body focused, a live slash
    /// token, and not Esc-dismissed. Independent of whether anything matches,
    /// so the picker can show its empty/no-match state (confirming the trigger
    /// fired) rather than silently showing nothing.
    private var slashActive: Bool {
        bodyFocused && !slashDismissed && slashToken != nil
    }

    /// Snippets matching the active slash query for the current From account
    /// (all available ones on an empty query — type `/` to browse).
    private var slashMatches: [Snippet] {
        guard let token = slashToken else { return [] }
        // Query never contains whitespace (slashToken ends on any whitespace).
        return SnippetMatch.ranked(store.allSnippets,
                                   query: token.query,
                                   accountId: fromAccountId)
    }

    /// Keep the highlight on the snippet the user already pointed at when it
    /// still ranks in the current matches; otherwise fall back to the top
    /// ranked hit (exact/prefix first via `SnippetMatch.ranked`).
    private func syncSlashSelection() {
        let matches = slashMatches
        if matches.isEmpty {
            slashSelectionId = nil
            return
        }
        if let id = slashSelectionId, matches.contains(where: { $0.listId == id }) {
            return
        }
        slashSelectionId = matches.first?.listId
    }

    /// Routes compose-body chords the NSTextView would otherwise swallow:
    /// ⌘K → link sheet; ↑/↓/Return/Tab/Esc → `/` picker while it's showing;
    /// Tab → greeting ghost accept when a Hi/Hey suggestion is live.
    /// Unmodified keys only for the picker — ⌘-Return (send) and friends pass.
    private func installSlashKeyMonitor() {
        guard slashKeyMonitor == nil else { return }
        slashKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control])
            // Gmail-style link insert. ContentView already stands down on
            // ⌘K while compose text has focus; we own it here. Require pure
            // ⌘ (no ⇧/⌥/⌃) so ⌘⇧K doesn't open the sheet.
            if mods == .command,
               !event.modifierFlags.contains(.shift),
               event.charactersIgnoringModifiers?.lowercased() == "k",
               bodyFocused {
                openLinkSheet()
                return nil
            }
            guard mods.isEmpty else { return event }
            // Greeting Tab must run before the slash-picker gate: when the
            // picker is up it owns Tab, but otherwise Tab accepts "Hi Name,".
            if !slashActive, event.keyCode == 48, acceptGreetingSuggestion() {
                return nil
            }
            guard slashActive else { return event }
            // Esc: ContentView owns dismiss via slashPickerVisible (installs
            // first, FIFO). This branch is a backup if that gate is stale.
            if event.keyCode == 53 {  // Esc — keep the typed text
                slashDismissed = true
                return nil
            }
            let matches = slashMatches
            guard !matches.isEmpty else { return event }
            let idx = matches.firstIndex(where: { $0.listId == slashSelectionId }) ?? 0
            switch event.keyCode {
            case 125:  // ↓
                slashSelectionId = matches[min(idx + 1, matches.count - 1)].listId
                return nil
            case 126:  // ↑
                slashSelectionId = matches[max(idx - 1, 0)].listId
                return nil
            case 36, 76, 48:  // Return, keypad Enter, Tab
                insertSlashSnippet(matches[idx])
                return nil
            default:
                return event
            }
        }
    }

    /// Captures the body selection (or caret) and opens the link sheet.
    /// If the caret sits inside an existing `[text](url)`, edit that span.
    private func openLinkSheet() {
        // Prefer the live field editor so we get the real selection; fall
        // back to end-of-body when focus hasn't landed yet.
        let nsBody = body_ as NSString
        var location = nsBody.length
        var length = 0
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView,
           tv.string == body_ {
            location = tv.selectedRange().location
            length = tv.selectedRange().length
            // Clamp in case the binding and view briefly diverge.
            if location > nsBody.length { location = nsBody.length; length = 0 }
            if location + length > nsBody.length { length = nsBody.length - location }
        }
        let sel = NSRange(location: location, length: length)
        guard let range = ComposeLinks.stringRange(nsRange: sel, in: body_) else { return }

        if length == 0, let existing = ComposeLinks.link(at: range.lowerBound, in: body_) {
            let full = ComposeLinks.nsRange(of: existing.range, in: body_)
            linkSelLocation = full.location
            linkSelLength = full.length
            linkInitialText = existing.text
            linkInitialURL = existing.url
            linkIsEditing = true
            showLinkSheet = true
            return
        }

        // ⌘K on a bare URL/email: never open the sheet. If it already
        // auto-links (and paints blue), leave the body alone — no [url](url)
        // doubling. Otherwise wrap as markdown so it becomes a real link.
        // Skip when the selection partially overlaps an existing markdown
        // link (fall back to the sheet rather than guess intent).
        if length > 0, !overlapsLinkWithoutExactCover(range) {
            switch ComposeLinks.bareURLCmdK(in: body_, selection: range) {
            case .alreadyLinked:
                bodyFocused = true
                return
            case .wrap(let next):
                let delta = (next as NSString).length - nsBody.length
                setBody(next, caretUTF16: location + length + delta)
                bodyFocused = true
                return
            case .none:
                break
            }
        }

        linkSelLocation = location
        linkSelLength = length
        linkInitialText = length > 0 ? nsBody.substring(with: sel) : ""
        linkInitialURL = ""
        linkIsEditing = false
        showLinkSheet = true
    }

    /// True when `range` overlaps an existing markdown link's span but
    /// isn't exactly that span — the "partial overlap" case where we
    /// deliberately fall back to the sheet instead of guessing intent.
    private func overlapsLinkWithoutExactCover(_ range: Range<String.Index>) -> Bool {
        ComposeLinks.markdownLinks(in: body_).contains { link in
            link.range.overlaps(range) && link.range != range
        }
    }

    private func applyLink(text: String, url: String) {
        let sel = NSRange(location: linkSelLocation, length: linkSelLength)
        guard let range = ComposeLinks.stringRange(nsRange: sel, in: body_) else { return }
        // Bare-URL selection: empty/same-as-URL label only no-ops when the
        // entered href matches the selection. A changed URL replaces as bare
        // text (auto-links on send). Distinct display text wraps as markdown.
        let selected = String(body_[range])
        if let existingHref = ComposeLinks.selfLink(forSelection: selected) {
            switch ComposeLinks.bareURLApply(label: text, href: url,
                                             existingHref: existingHref) {
            case .noOp:
                bodyFocused = true
                return
            case .replaceBare(let bare):
                var next = body_
                next.replaceSubrange(range, with: bare)
                let oldLen = (body_ as NSString).length
                let delta = (next as NSString).length - oldLen
                setBody(next, caretUTF16: linkSelLocation + linkSelLength + delta)
                bodyFocused = true
                return
            case .wrap:
                break
            }
        }
        guard let next = ComposeLinks.applyLink(in: body_, selection: range,
                                                text: text.isEmpty ? nil : text,
                                                url: url) else { return }
        let oldLen = (body_ as NSString).length
        let delta = (next as NSString).length - oldLen
        setBody(next, caretUTF16: linkSelLocation + linkSelLength + delta)
        bodyFocused = true
    }

    private func removeLinkAtSelection() {
        let sel = NSRange(location: linkSelLocation, length: linkSelLength)
        guard let range = ComposeLinks.stringRange(nsRange: sel, in: body_),
              let existing = ComposeLinks.link(at: range.lowerBound, in: body_) else { return }
        let next = ComposeLinks.removeLink(existing, in: body_)
        // Park at the start of where the link was.
        setBody(next, caretUTF16: NSRange(existing.range, in: body_).location)
        bodyFocused = true
    }

    /// Replaces the typed `/query` with the chosen snippet, expanded.
    private func insertSlashSnippet(_ snippet: Snippet) {
        let head = String(body_[..<authoredHeadEnd])
        let headUTF16 = (head as NSString).length
        // Same rule as slashToken: caret past the head → no insert.
        guard bodyCaretUTF16 >= 0, bodyCaretUTF16 <= headUTF16 else { return }
        guard let token = SnippetInsertion.slashToken(in: head, caretUTF16: bodyCaretUTF16) else { return }
        let expanded = expandSnippet(snippet)
        // Token range is inside `head`; map to UTF-16 offsets in the full body
        // (authored head is always a prefix, so offsets match).
        let nsRange = NSRange(token.range, in: head)
        let nsBody = body_ as NSString
        let before = nsBody.substring(to: nsRange.location)
        let after = nsBody.substring(from: nsRange.location + nsRange.length)
        let next = before + expanded + after
        // Park the caret just after the inserted text so a second `/` can
        // fire immediately without the picker latching onto mid-snippet text.
        setBody(next, caretUTF16: (before as NSString).length + (expanded as NSString).length)
        slashSelectionId = nil
        slashDismissed = false
    }

    /// Inserts a snippet where the user writes: above the quoted original on
    /// a reply/forward, appended (with clean spacing) otherwise. `{{variables}}`
    /// (first_name, name, email, date…) are filled from the first recipient.
    private func insertSnippet(_ snippet: Snippet) {
        let text = expandSnippet(snippet)
        if let quote = body_.range(of: "\n" + ForwardComposer.marker)
            ?? body_.range(of: #"\n+On .+ wrote:\n"#, options: .regularExpression) {
            var head = String(body_[..<quote.lowerBound])
            while head.hasSuffix("\n") { head.removeLast() }
            let written = head.isEmpty ? text : head + "\n" + text
            let next = written + "\n" + String(body_[quote.lowerBound...])
            setBody(next, caretUTF16: (written as NSString).length)
        } else if body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setBody(text, caretUTF16: (text as NSString).length)
        } else {
            let sep = body_.hasSuffix("\n") ? "" : "\n"
            let next = body_ + sep + text
            setBody(next, caretUTF16: (next as NSString).length)
        }
    }

    /// Expands a snippet's variables — and, for move-to-bcc snippets, first
    /// performs the intro shuffle (To → Bcc, Cc → To) so `{bcc_*}` names the
    /// introducer and `{first_name}` names the person now in To.
    private func expandSnippet(_ snippet: Snippet) -> String {
        var ctx = SnippetExpander.Context()
        ctx.date = SnippetExpander.today(Date())
        ctx.myName = store.sendIdentities.first {
            $0.email.caseInsensitiveCompare(fromEmail) == .orderedSame
                && $0.accountId.caseInsensitiveCompare(fromAccountId) == .orderedSame
        }?.displayName
            ?? store.accounts.first { $0.id == fromAccountId }?.senderName
            ?? ""
        // Reply tokens are often bare addresses (display names stripped when
        // building To/Cc). Recover names from the original headers + contacts
        // so `{bcc_first_name}` / `{first_name}` don't invent "Jrsykes".
        let names = snippetNameByEmail()
        if snippet.movesToBcc {
            if let intro = toTokens.first {
                (ctx.bccName, ctx.bccEmail) = person(from: intro, nameByEmail: names)
            }
            let moved = SnippetInsertion.moveToBcc(to: toTokens, cc: ccTokens, bcc: bccTokens)
            toTokens = moved.to
            ccTokens = moved.cc
            bccTokens = moved.bcc
            if !bccTokens.isEmpty { showCc = true; showBcc = true }
        } else if let firstBcc = bccTokens.first {
            (ctx.bccName, ctx.bccEmail) = person(from: firstBcc, nameByEmail: names)
        }
        if let first = toTokens.first ?? (toDraft.contains("@") ? toDraft : nil) {
            (ctx.recipientName, ctx.recipientEmail) = person(from: first, nameByEmail: names)
        }
        return SnippetExpander.expand(snippet.body, ctx)
    }

    /// email → display name for snippet variables. Original-message headers
    /// win over mined contacts (header names are fresher on the reply target).
    private func snippetNameByEmail() -> [String: String] {
        var contactMap: [String: String] = [:]
        for c in store.contacts where !c.name.isEmpty {
            contactMap[c.email.lowercased()] = c.name
        }
        var headerTokens: [String] = []
        if let original {
            for header in [original.fromHeader, original.toHeader, original.ccHeader] {
                headerTokens.append(contentsOf: MessageParser.splitAddresses(header))
            }
        }
        return GreetingAutocomplete.nameByEmail(
            headerTokens: headerTokens, contactEmailToName: contactMap)
    }

    /// Name + email from a recipient token ("Alice <a@x.com>" or bare address),
    /// with optional email→name recovery when reply setup stripped display names.
    private func person(from token: String,
                        nameByEmail: [String: String] = [:]) -> (name: String, email: String) {
        GreetingAutocomplete.person(from: token, nameByEmail: nameByEmail)
    }

    private func saveCurrentAsSnippet() {
        let alert = NSAlert()
        alert.messageText = "Snippet name"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            store.saveSnippet(name: field.stringValue, body: body_)
        }
    }

    /// Commits typed-but-uncommitted recipients and packages the message
    /// (attachment data loaded now — the card closes before the send).
    /// Returns nil (with `error` set where relevant) when not sendable.
    private func buildPendingSend() -> MailStore.PendingSend? {
        // Typed-but-uncommitted addresses count as recipients.
        for (draft, tokens) in [(toDraft, $toTokens), (ccDraft, $ccTokens), (bccDraft, $bccTokens)] {
            let cleaned = draft.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            if cleaned.contains("@"), !tokens.wrappedValue.contains(cleaned) {
                tokens.wrappedValue.append(cleaned)
            }
        }
        toDraft = ""; ccDraft = ""; bccDraft = ""
        guard !toTokens.isEmpty || !bccTokens.isEmpty else { return nil }

        error = nil
        do {
            let attachments = try collectAttachments()
            return MailStore.PendingSend(
                accountId: fromAccountId,
                fromEmail: fromEmail,
                to: toTokens.joined(separator: ", "),
                cc: ccTokens.joined(separator: ", "),
                bcc: bccTokens.joined(separator: ", "),
                subject: subject, body: fullBody,
                // For forwards this is the forwarded original (supplies the
                // HTML body at send time); the send path knows not to thread it.
                replyTo: request.replyTo, forward: request.forward,
                forwardAll: request.forwardAll,
                attachments: attachments,
                // Live autosave chain — not the original editDraft only (B1).
                replacingDraft: liveDraft)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private func send() {
        // Claim finish before any work so a second click / ⌘↩ can't double-queue.
        // Unmount immediately: do not wait on an in-flight createDraft round-trip
        // (that made post-Send `e` archive feel stuck behind Gmail). Body comes
        // from the editor; liveDraft is the last *completed* autosave id.
        guard beginFinish() else { return }
        cancelInFlightPersist()
        guard let pending = buildPendingSend() else {
            // Not sendable (empty To:) — re-enable the card.
            abortFinish()
            return
        }
        store.queueSend(pending)
        close()
    }

    private func scheduleSend(at date: Date) {
        guard beginFinish() else { return }
        cancelInFlightPersist()
        guard let pending = buildPendingSend() else {
            abortFinish()
            return
        }
        store.scheduleSend(pending, at: date)
        close()
    }

    /// Drop a *debounced* autosave when Send packages content from the editor.
    /// Do not cancel an in-flight `persistTask`: `createDraft` may still land
    /// at Gmail after cancel, leaving an orphan with no delete path. Leave the
    /// task running; `performPersist` checks `didFinish` and deletes a late
    /// draft (or skips the upload if finish landed first). Discard still awaits
    /// idle so it can delete the real draft id.
    private func cancelInFlightPersist() {
        autosaveTask?.cancel()
        autosaveTask = nil
    }
}

// MARK: - Subject field (BiDi base writing direction)

/// Borderless subject field with per-content base writing direction.
/// SwiftUI `TextField` can right-align RTL but leaves base direction LTR, so
/// Hebrew subjects with Latin/punctuation still reorder wrong.
struct ComposeSubjectField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14, weight: .semibold)
        field.textColor = .labelColor
        field.placeholderString = "Subject"
        field.setAccessibilityIdentifier("composeSubject")
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        applyDirection(to: field, text: text)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text {
            field.stringValue = text
        }
        applyDirection(to: field, text: text)
    }

    private func applyDirection(to field: NSTextField, text: String) {
        let direction: NSWritingDirection
        let alignment: NSTextAlignment
        switch TextDirection.base(of: text) {
        case .rtl:
            direction = .rightToLeft
            alignment = .right
        case .ltr:
            direction = .leftToRight
            alignment = .left
        case .neutral:
            direction = .natural
            alignment = .natural
        }
        // While a field editor is live, touch ONLY the editor. Writing
        // alignment/baseWritingDirection on the field itself goes through the
        // cell and ends the editing session — the first typed character flips
        // neutral→LTR, and that write silently dropped keyboard focus (the
        // "subject unselects while I type" glitch). The field-level values
        // catch up on the next update after editing ends.
        if let editor = field.currentEditor() {
            if editor.baseWritingDirection != direction {
                editor.baseWritingDirection = direction
            }
            if editor.alignment != alignment {
                editor.alignment = alignment
            }
        } else {
            if field.baseWritingDirection != direction {
                field.baseWritingDirection = direction
            }
            if field.alignment != alignment {
                field.alignment = alignment
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
