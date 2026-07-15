import SwiftUI
import UniformTypeIdentifiers

/// Notion/Gmail-style compose: a docked card with recipient chips,
/// borderless fields, minimal footer.
struct ComposeView: View {
    @EnvironmentObject var store: MailStore

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
    /// Body focus is a plain Bool (not FocusState) because the body is an
    /// AppKit NSTextView — FocusState doesn't attach to NSViewRepresentable.
    @State private var bodyFocused = false
    /// Bridge so the format toolbar mutates the live text view + selection.
    @State private var formatTarget = ComposeBodyFormatTarget()

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

    /// Draft id chain for replace / send / discard (autosave may have moved it).
    private var liveDraft: Message? { replacingDraft ?? editingDraft }

    /// Claim the finish path immediately (before any await) so Send / Esc /
    /// Discard / Schedule can't re-enter and double-queue. Returns false if
    /// another finish is already in flight.
    @discardableResult
    private func beginFinish() -> Bool {
        guard !didFinish else { return false }
        didFinish = true
        autosaveTask?.cancel()
        autosaveTask = nil
        return true
    }

    /// Undo `beginFinish` when the action can't complete (e.g. empty To:).
    private func abortFinish() {
        didFinish = false
    }

    private func close() {
        didFinish = true
        autosaveTask?.cancel()
        autosaveTask = nil
        store.composeMinimized = false
        store.composeRequest = nil
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
    /// instead of clipping into it. Cap high enough for longer drafts so
    /// the card footer stays on-screen; floor so an empty reply still has
    /// a usable writing surface.
    private var bodyEditorMaxHeight: CGFloat {
        guard !quotedTail.isEmpty else { return .infinity }
        // 14pt body font + 5pt lineSpacing ≈ 19pt per line; +16 for the
        // editor's top/bottom padding around the first/last fragment.
        let lineHeight: CGFloat = 19
        // Card is 620pt wide with ~14pt chrome; ~72 chars fit at 14pt.
        let charsPerLine = 72
        var visualLines: CGFloat = 0
        for line in body_.components(separatedBy: "\n") {
            let len = max(line.count, 1)
            visualLines += CGFloat((len + charsPerLine - 1) / charsPerLine)
        }
        if visualLines < 1 { visualLines = 1 }
        let contentHeight = 16 + visualLines * lineHeight
        return min(max(contentHeight, 120), 280)
    }

    /// Focuses the body editor. Setting the FocusState synchronously in
    /// onAppear fires before the TextEditor is ready and gets dropped —
    /// same trick as AddressField's autoFocus, delayed a beat.
    private func focusBody() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { bodyFocused = true }
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
        body_ = newBody
        let maxLen = (newBody as NSString).length
        bodyCaretUTF16 = max(0, min(caretUTF16, maxLen))
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
            replacingDraft = saved
            lastSavedFingerprint = fingerprint
            if silent { didSilentSave = true }
            draftStatus = .saved
            // Content may have changed during the network round-trip — chain
            // one more silent save so we don't leave an older body as "the"
            // draft. Only after success (failed saves must not recurse).
            if silent, hasContent, contentFingerprint != lastSavedFingerprint {
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
        .accessibilityIdentifier(isInline ? "composeInline" : "composeCard")
        .onAppear {
            store.composeMinimized = false
            isMinimized = false
            // Seed the replace chain before prefill so undo-send restores any
            // draft that Send was about to delete.
            replacingDraft = editingDraft ?? request.restore?.replacingDraft
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
        }
        .onDisappear {
            // Unmounted without an explicit exit: a new compose/reply request
            // replaced this card (single-key shortcuts allow that while
            // minimized). Keep the work as a draft instead of dropping it.
            if !didFinish { saveDraftIfNeeded() }
            store.composeMinimized = false
            autosaveTask?.cancel()
            if let monitor = slashKeyMonitor {
                NSEvent.removeMonitor(monitor)
                slashKeyMonitor = nil
            }
        }
        .onChange(of: body_) { scheduleAutosave() }
        .onChange(of: subject) { scheduleAutosave() }
        .onChange(of: toTokens) { scheduleAutosave() }
        .onChange(of: ccTokens) { scheduleAutosave() }
        .onChange(of: bccTokens) { scheduleAutosave() }
        .onChange(of: attachmentURLs) { scheduleAutosave() }
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
            if case .success(let urls) = result { attachmentURLs.append(contentsOf: urls) }
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
            if isInline {
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
            if !isInline { setMinimized(true) }
        }
        .help(isInline ? "Reply" : "Minimize compose")
    }

    @ViewBuilder
    private var closeButton: some View {
        // Esc closes only while expanded — minimized compose yields Esc to the
        // mailbox (reading-pane / multi-select ladder in ContentView).
        if isMinimized {
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
        switch draftStatus {
        case .idle:
            EmptyView()
        case .saving:
            Text("Saving…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("draftStatusSaving")
        case .saved:
            Text("Draft saved")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("draftStatusSaved")
        case .failed:
            Text("Draft not saved")
                .font(.system(size: 12))
                .foregroundStyle(.red.opacity(0.85))
                .accessibilityIdentifier("draftStatusFailed")
        }
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

            TextField("Subject", text: $subject)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .padding(.vertical, 8)
            Divider()

            // Markdown source editor: live highlight + ⌘B/⌘I/… shortcuts.
            ComposeBodyEditor(text: $body_, isFocused: $bodyFocused,
                              caretUTF16: $bodyCaretUTF16,
                              formatTarget: formatTarget, fontSize: 14)
                .padding(.top, 10)
                .padding(.bottom, 6)
                // Grow with authored content while the quote is collapsed so
                // short replies don't scroll under the "…" pill; see
                // bodyEditorMaxHeight.
                .frame(minHeight: 120, maxHeight: bodyEditorMaxHeight)
                .onChange(of: body_) {
                    syncSlashSelection()
                    if slashToken == nil { slashDismissed = false }
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
            if slashActive {
                SlashSnippetPicker(snippets: slashMatches,
                                   query: slashToken?.query ?? "",
                                   selectionId: slashSelectionId,
                                   choose: { insertSlashSnippet($0) })
                    .padding(.top, 4)
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
                Spacer(minLength: 0)
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
                .environmentObject(store)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 10) {
                footerButton("paperclip", help: "Attach files") { showFilePicker = true }

                footerButton("link", help: "Insert link (⌘K)") { openLinkSheet() }

                Button {
                    withAnimation(.easeOut(duration: 0.12)) { showSnippets.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "text.badge.plus")
                        Text("Snippets").font(.system(size: 12))
                    }
                    .foregroundStyle(showSnippets ? Color.notionAccent : Color.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("/", modifiers: .command)
                .help("Insert a saved snippet (⌘/)")

                // Available for replies, forwards, and new mail — the draft is
                // generated locally and streamed into the body.
                footerButton(drafting ? "hourglass" : "sparkles",
                             help: "Draft with local AI (Ollama)") { draftWithAI() }
                    .disabled(drafting)

                // Markdown format strip (bold/italic/headers/math…). Link is
                // the dedicated button above (⌘K sheet); bar routes the rest.
                ComposeFormatBar { action in
                    if action == .link { openLinkSheet() }
                    else { formatTarget.run(action) }
                }
                .padding(.leading, 2)

                Spacer()

                Button {
                    // Discard: delete the live autosave chain (not only editDraft).
                    discardAndClose()
                } label: {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(liveDraft != nil ? "Discard (deletes this draft)" : "Discard without saving")
                // Notion-style draft status where "Close" used to sit — dismiss
                // is the header ✕ (and Esc). Status only after the user types.
                draftStatusLabel
                    .padding(.horizontal, 4)

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
                            .frame(height: 22)
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
                            .frame(height: 22)
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
            .padding(.top, 8)
        }
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

    private func footerButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
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
        // "Draft email to X" from a message header: new mail, To prefilled.
        if let to = request.prefillTo, original == nil {
            toTokens = [to]
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
            prompt = Ollama.draftReply(
                originalFrom: original.fromHeader,
                originalBody: MessageParser.replyQuotableText(
                    text: original.bodyText, html: original.bodyHTML),
                intent: intent,
                userEmail: fromEmail)
        } else {
            prompt = Ollama.draftNew(intent: intent, userEmail: fromEmail)
        }
        let quoteTail = quote.isEmpty ? "" : "\n" + quote
        Task {
            do {
                // Stream tokens in as the local model produces them.
                var accumulated = ""
                for try await piece in Ollama.generateStream(prompt: prompt) {
                    accumulated += piece
                    let snapshot = accumulated
                    await MainActor.run {
                        // Caret follows the growing draft (end of authored head).
                        setBody(snapshot + quoteTail,
                                caretUTF16: (snapshot as NSString).length)
                    }
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
            await MainActor.run { drafting = false }
        }
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
    /// ⌘K → link sheet; ↑/↓/Return/Tab/Esc → `/` picker while it's showing.
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
            guard slashActive else { return event }
            // Esc drops the picker even when nothing matches (so the trigger
            // is escapable); the rest only act when there's a snippet to pick.
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

        // ⌘K on a selection that's already a bare URL/email should just
        // link it — no sheet, no retyping. Skip the short-circuit (and
        // fall back to the sheet, same as before) when the selection
        // overlaps an existing markdown link without exactly covering it;
        // trying to be clever about partial overlaps isn't worth it.
        if length > 0, !overlapsLinkWithoutExactCover(range) {
            let selected = nsBody.substring(with: sel)
            if let href = ComposeLinks.selfLink(forSelection: selected),
               let next = ComposeLinks.applyLink(in: body_, selection: range,
                                                 text: selected, url: href) {
                // Park after the inserted markdown link.
                let delta = (next as NSString).length - nsBody.length
                setBody(next, caretUTF16: location + length + delta)
                bodyFocused = true
                return
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
        guard let range = ComposeLinks.stringRange(nsRange: sel, in: body_),
              let next = ComposeLinks.applyLink(in: body_, selection: range,
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
        if snippet.movesToBcc {
            if let intro = toTokens.first {
                (ctx.bccName, ctx.bccEmail) = person(from: intro)
            }
            let moved = SnippetInsertion.moveToBcc(to: toTokens, cc: ccTokens, bcc: bccTokens)
            toTokens = moved.to
            ccTokens = moved.cc
            bccTokens = moved.bcc
            if !bccTokens.isEmpty { showCc = true; showBcc = true }
        } else if let firstBcc = bccTokens.first {
            (ctx.bccName, ctx.bccEmail) = person(from: firstBcc)
        }
        if let first = toTokens.first ?? (toDraft.contains("@") ? toDraft : nil) {
            (ctx.recipientName, ctx.recipientEmail) = person(from: first)
        }
        return SnippetExpander.expand(snippet.body, ctx)
    }

    /// Name + email from a recipient token ("Alice <a@x.com>" or bare address,
    /// deriving a friendly name from the local part: john.doe → John Doe).
    private func person(from token: String) -> (name: String, email: String) {
        if let lt = token.firstIndex(of: "<"), let gt = token.firstIndex(of: ">"), lt < gt {
            return (String(token[..<lt]).trimmingCharacters(in: CharacterSet(charactersIn: " \"")),
                    String(token[token.index(after: lt)..<gt]))
        }
        let email = token.trimmingCharacters(in: .whitespaces)
        let local = email.split(separator: "@").first.map(String.init) ?? ""
        let name = local
            .split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        return (name, email)
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
        // Claim finish before any await so a second click / ⌘↩ can't queue
        // two sends while we wait on in-flight autosave (N1).
        guard beginFinish() else { return }
        Task { @MainActor in
            await awaitPersistIdle()
            guard let pending = buildPendingSend() else {
                // Not sendable (empty To:) — re-enable the card.
                abortFinish()
                return
            }
            store.queueSend(pending)
            close()
        }
    }

    private func scheduleSend(at date: Date) {
        guard beginFinish() else { return }
        Task { @MainActor in
            await awaitPersistIdle()
            guard let pending = buildPendingSend() else {
                abortFinish()
                return
            }
            store.scheduleSend(pending, at: date)
            close()
        }
    }
}
