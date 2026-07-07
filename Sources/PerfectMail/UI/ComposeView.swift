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

    @State private var fromAccount: String = ""
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
    /// Slash trigger: highlighted row in the `/` picker, and whether the user
    /// Esc-dismissed the current token (cleared when the token goes away).
    @State private var slashSelection = 0
    @State private var slashDismissed = false
    /// Local keyDown monitor that steals ↑/↓/Return/Tab/Esc while the `/`
    /// picker is up — the NSTextView behind TextEditor consumes those keys
    /// before SwiftUI's onKeyPress ever sees them.
    @State private var slashKeyMonitor: Any?
    @State private var showScheduleSheet = false
    @State private var drafting = false
    @State private var error: String?
    @FocusState private var bodyFocused: Bool

    @State private var initialBody = ""
    @State private var initialSubject = ""
    @State private var initialRecipients: [String] = []

    private func close() {
        store.composeRequest = nil
    }

    /// The complete message body: what's in the editor plus the collapsed
    /// quote, joined exactly the way the old inline prefill did ("\n\n" +
    /// quote) so the send path still recognizes an untouched forward block.
    private var fullBody: String {
        quotedTail.isEmpty ? body_ : body_ + "\n\n" + quotedTail
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
        body_ = fullBody
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
        body_ = head
        // A never-edited body collapses back to pure prefill.
        if untouched { initialBody = "" }
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

    /// Close and keep the work: unsent content becomes a real Gmail draft.
    private func saveAndClose() {
        // Typed-but-uncommitted addresses count too.
        for (draft, tokens) in [(toDraft, $toTokens), (ccDraft, $ccTokens), (bccDraft, $bccTokens)] {
            let cleaned = draft.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            if cleaned.contains("@"), !tokens.wrappedValue.contains(cleaned) {
                tokens.wrappedValue.append(cleaned)
            }
        }
        toDraft = ""; ccDraft = ""; bccDraft = ""
        if hasContent {
            // Best effort on the files: an unreadable pick shouldn't lose the text.
            let attachments = (try? collectAttachments()) ?? restoredAttachments
            // Closed while the prefilled files were still downloading: their
            // chips aren't in yet, so re-fetch them before saving — otherwise
            // the re-saved draft would silently drop them.
            let pendingSource = loadingAttachments
                ? (editingDraft ?? (request.forward ? original : nil)) : nil
            let (from, to, cc, bcc, subj, body, old) =
                (fromAccount, toTokens.joined(separator: ", "), ccTokens.joined(separator: ", "),
                 bccTokens.joined(separator: ", "), subject, fullBody, editingDraft)
            // Like the send path, a forward's original rides along so the
            // draft keeps its HTML formatting (it won't thread the draft).
            let (reply, isForward) = (request.replyTo, request.forward)
            Task {
                var atts = attachments
                if let source = pendingSource {
                    atts = ((try? await store.loadAttachments(for: source)) ?? []) + atts
                }
                await store.saveDraft(from: from, to: to, cc: cc, bcc: bcc, subject: subj,
                                      body: body, replyTo: reply, forward: isForward,
                                      attachments: atts, replacing: old)
            }
        }
        close()
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
            // Header: subject as title, close (saves a draft).
            HStack {
                Text(editingDraft != nil
                     ? "Draft: \(subject.isEmpty ? "(no subject)" : subject)"
                     : (subject.isEmpty ? "New Message" : subject))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    saveAndClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help(hasContent ? "Close (saves as draft)" : "Close")
            }
            .padding(.bottom, 6)

            // Reply/forward context — you're inside this Gmail thread.
            if let original {
                HStack(spacing: 5) {
                    Image(systemName: request.forward ? "arrowshape.turn.up.right" : "arrowshape.turn.up.left")
                        .font(.system(size: 10))
                    Text(request.forward
                         ? "Forwarding message from \(MessageParser.displayName(fromHeader: original.fromHeader))"
                         : "Replying to \(MessageParser.displayName(fromHeader: original.fromHeader))")
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            }

            // From row — laid out like the address rows (30pt label gutter)
            // so the account text lines up with the To/Cc/Bcc fields.
            HStack(alignment: .center, spacing: 6) {
                Text("From")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .leading)
                Menu {
                    ForEach(store.accounts) { account in
                        Button(menuTitle(account)) { fromAccount = account.id }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(fromAccount.isEmpty ? "Select account" : fromAccount)
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

            TextEditor(text: $body_)
                .font(.system(size: 14))
                .lineSpacing(5)
                .scrollContentBackground(.hidden)
                .focused($bodyFocused)
                .padding(.top, 10)
                // NSTextView pads each line fragment 5pt; cancel it so the
                // body text lines up with the Subject/From/To column.
                .padding(.horizontal, -5)
                .padding(.bottom, 6)
                // While the quote is collapsed, don't let the editor swallow
                // the card — keeps the "…" pill near the text, not the footer.
                .frame(minHeight: 120, maxHeight: quotedTail.isEmpty ? .infinity : 160)
                .onChange(of: body_) {
                    slashSelection = 0
                    if slashToken == nil { slashDismissed = false }
                }

            // The `/` picker renders directly under the editor, where the
            // cursor is, so it reads as results for what you're typing.
            if slashActive {
                SlashSnippetPicker(snippets: slashMatches,
                                   query: slashToken?.query ?? "",
                                   selection: min(slashSelection, max(slashMatches.count - 1, 0)),
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
                })
                .environmentObject(store)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 10) {
                footerButton("paperclip", help: "Attach files") { showFilePicker = true }

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

                Spacer()

                Button {
                    // Discard: no draft saved; editing an existing draft deletes it.
                    if let draft = editingDraft {
                        Task { await store.deleteUnderlyingDraft(draft) }
                    }
                    close()
                } label: {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(editingDraft != nil ? "Discard (deletes this draft)" : "Discard without saving")
                Button("Cancel") { saveAndClose() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(hasContent ? "Close (saves as draft)" : "Close")

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
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send (10s undo window)")

                    Menu {
                        ForEach(SendSchedule.allCases, id: \.self) { preset in
                            let date = preset.date()
                            Button("\(preset.title)  (\(date.formatted(.dateTime.weekday(.abbreviated).hour().minute())))") {
                                scheduleSend(at: date)
                            }
                        }
                        Divider()
                        Button("Pick date & time…") { showScheduleSheet = true }
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
                    // .button + .plain renders custom labels reliably on
                    // macOS (same recipe as the From menu).
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Schedule send")
                }
                .opacity(cannotSend ? 0.5 : 1)
                .disabled(cannotSend)
            }
            .padding(.top, 8)
        }
        .padding(14)
        .onAppear {
            prefill()
            installSlashKeyMonitor()
        }
        .onDisappear {
            if let monitor = slashKeyMonitor {
                NSEvent.removeMonitor(monitor)
                slashKeyMonitor = nil
            }
        }
        .onChange(of: store.accounts) {
            // Accounts can finish loading after the card appears — backfill From.
            if fromAccount.isEmpty {
                fromAccount = store.activeAccountId ?? store.accounts.first?.id ?? ""
            }
        }
        .sheet(isPresented: $showScheduleSheet) {
            ScheduleSendSheet { date in scheduleSend(at: date) }
        }
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attachmentURLs.append(contentsOf: urls) }
        }
    }

    private var cannotSend: Bool {
        fromAccount.isEmpty
            || loadingAttachments   // forwarded files still downloading
            || (toTokens.isEmpty && !toDraft.contains("@")
                && bccTokens.isEmpty && !bccDraft.contains("@"))
    }

    private func menuTitle(_ account: Account) -> String {
        account.displayName == account.id ? account.id : "\(account.displayName) — \(account.id)"
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
            fromAccount = r.accountId
            toTokens = MessageParser.splitAddresses(r.to).filter { $0.contains("@") }
            ccTokens = MessageParser.splitAddresses(r.cc).filter { $0.contains("@") }
            if !ccTokens.isEmpty { showCc = true }
            bccTokens = MessageParser.splitAddresses(r.bcc).filter { $0.contains("@") }
            if !bccTokens.isEmpty { showBcc = true }
            subject = r.subject
            body_ = r.body
            restoredAttachments = r.attachments
            initialBody = ""   // an undone send always counts as content
            focusBody()
            return
        }

        // Editing an existing Gmail draft: load its fields verbatim.
        if let draft = editingDraft {
            fromAccount = draft.accountId
            toTokens = MessageParser.splitAddresses(draft.toHeader)
                .map { MessageParser.emailAddress($0) }.filter { $0.contains("@") }
            ccTokens = MessageParser.splitAddresses(draft.ccHeader)
                .map { MessageParser.emailAddress($0) }.filter { $0.contains("@") }
            if !ccTokens.isEmpty { showCc = true }
            bccTokens = MessageParser.splitAddresses(draft.bccHeader)
                .map { MessageParser.emailAddress($0) }.filter { $0.contains("@") }
            if !bccTokens.isEmpty { showBcc = true }
            subject = draft.subject
            body_ = draft.bodyText
            initialBody = ""   // a draft always counts as content
            // The draft's files come back as chips — re-saving keeps them.
            prefillAttachments(of: draft)
            focusBody()
            return
        }

        // Reply/forward: send from the account that received it. New mail:
        // the account currently in view, falling back to the primary account.
        fromAccount = original?.accountId ?? store.activeAccountId
            ?? store.accounts.first?.id ?? ""
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
        let ownAddresses = Set(store.accounts.map { $0.id.lowercased() })
        let sender = MessageParser.emailAddress(original.fromHeader)

        if request.forward {
            let subj = original.subject
            subject = subj.lowercased().hasPrefix("fwd:") ? subj : "Fwd: \(subj)"
            // Gmail-style forwarded block instead of "> " quoting. Kept
            // verbatim and collapsed behind the "…" button: the send path
            // recomputes this block, and an untouched one lets the send carry
            // the original HTML formatting alongside the plain text. The
            // editor starts empty (cursor at the top); focus stays on To.
            quotedTail = ForwardComposer.forwardBlock(
                fromHeader: original.fromHeader, date: original.date,
                subject: original.subject, toHeader: original.toHeader,
                ccHeader: original.ccHeader, bodyText: original.bodyText)
            // Forwards carry the original's attachments (standard behavior).
            // They arrive async; Send holds until they're in.
            prefillAttachments(of: original)
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
        // cursor lands at the top.
        let when = original.date.formatted(date: .abbreviated, time: .shortened)
        let who = "\(MessageParser.displayName(fromHeader: original.fromHeader)) <\(sender)>"
        let quoted = original.bodyText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        quotedTail = "\nOn \(when), \(who) wrote:\n\(quoted)"
        focusBody()
    }

    /// Pulls a message's attachments (forwarded original, or a draft being
    /// reopened) into the card as removable chips. They arrive async; Send
    /// holds until the download finishes, and they don't count as authored
    /// content for the save-on-close heuristic.
    private func prefillAttachments(of message: Message) {
        guard message.hasAttachment else { return }
        loadingAttachments = true
        Task {
            do {
                let atts = try await store.loadAttachments(for: message)
                await MainActor.run {
                    restoredAttachments.append(contentsOf: atts)
                    prefilledAttachmentNames = atts.map(\.filename)
                }
            } catch {
                await MainActor.run {
                    self.error = "Couldn't load the attachments: \(error.localizedDescription)"
                }
            }
            await MainActor.run { loadingAttachments = false }
        }
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
                originalBody: original.bodyText,
                intent: intent,
                userEmail: fromAccount)
        } else {
            prompt = Ollama.draftNew(intent: intent, userEmail: fromAccount)
        }
        let quoteTail = quote.isEmpty ? "" : "\n" + quote
        Task {
            do {
                // Stream tokens in as the local model produces them.
                var accumulated = ""
                for try await piece in Ollama.generateStream(prompt: prompt) {
                    accumulated += piece
                    let snapshot = accumulated
                    await MainActor.run { body_ = snapshot + quoteTail }
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

    /// The active `/query` the user is typing at the end of their text, if any.
    private var slashToken: SnippetInsertion.SlashToken? {
        SnippetInsertion.slashToken(in: String(body_[..<authoredHeadEnd]))
    }

    /// Whether the `/` picker should be showing: body focused, a live slash
    /// token, and not Esc-dismissed. Independent of whether anything matches,
    /// so the picker can show its empty/no-match state (confirming the trigger
    /// fired) rather than silently showing nothing.
    private var slashActive: Bool {
        bodyFocused && !slashDismissed && slashToken != nil
    }

    /// Snippets matching the active slash query (all of them on an empty
    /// query — type `/` to browse everything, Claude-style).
    private var slashMatches: [Snippet] {
        guard let token = slashToken else { return [] }
        let q = token.query.trimmingCharacters(in: .whitespaces)
        return store.snippets().filter {
            q.isEmpty || $0.name.localizedCaseInsensitiveContains(q)
        }
    }

    /// Routes ↑/↓/Return/Tab/Esc to the `/` picker while it's showing.
    /// Unmodified keys only — ⌘-Return (send) and friends pass through.
    private func installSlashKeyMonitor() {
        guard slashKeyMonitor == nil else { return }
        slashKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty
            else { return event }
            guard slashActive else { return event }
            // Esc drops the picker even when nothing matches (so the trigger
            // is escapable); the rest only act when there's a snippet to pick.
            if event.keyCode == 53 {  // Esc — keep the typed text
                slashDismissed = true
                return nil
            }
            let matches = slashMatches
            guard !matches.isEmpty else { return event }
            switch event.keyCode {
            case 125:  // ↓
                slashSelection = min(slashSelection + 1, matches.count - 1)
                return nil
            case 126:  // ↑
                slashSelection = max(slashSelection - 1, 0)
                return nil
            case 36, 76, 48:  // Return, keypad Enter, Tab
                insertSlashSnippet(matches[min(slashSelection, matches.count - 1)])
                return nil
            default:
                return event
            }
        }
    }

    /// Replaces the typed `/query` with the chosen snippet, expanded.
    private func insertSlashSnippet(_ snippet: Snippet) {
        let head = String(body_[..<authoredHeadEnd])
        guard let token = SnippetInsertion.slashToken(in: head) else { return }
        let start = head.distance(from: head.startIndex, to: token.range.lowerBound)
        let end = head.distance(from: head.startIndex, to: token.range.upperBound)
        let lo = body_.index(body_.startIndex, offsetBy: start)
        let hi = body_.index(body_.startIndex, offsetBy: end)
        body_.replaceSubrange(lo..<hi, with: expandSnippet(snippet))
        slashSelection = 0
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
            body_ = written + "\n" + String(body_[quote.lowerBound...])
        } else if body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body_ = text
        } else {
            body_ += (body_.hasSuffix("\n") ? "" : "\n") + text
        }
    }

    /// Expands a snippet's variables — and, for move-to-bcc snippets, first
    /// performs the intro shuffle (To → Bcc, Cc → To) so `{bcc_*}` names the
    /// introducer and `{first_name}` names the person now in To.
    private func expandSnippet(_ snippet: Snippet) -> String {
        var ctx = SnippetExpander.Context()
        ctx.date = SnippetExpander.today(Date())
        ctx.myName = store.accounts.first { $0.id == fromAccount }?.senderName ?? ""
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
                accountId: fromAccount,
                to: toTokens.joined(separator: ", "),
                cc: ccTokens.joined(separator: ", "),
                bcc: bccTokens.joined(separator: ", "),
                subject: subject, body: fullBody,
                // For forwards this is the forwarded original (supplies the
                // HTML body at send time); the send path knows not to thread it.
                replyTo: request.replyTo, forward: request.forward,
                attachments: attachments,
                replacingDraft: editingDraft)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private func send() {
        guard let pending = buildPendingSend() else { return }
        store.queueSend(pending)
        close()
    }

    private func scheduleSend(at date: Date) {
        guard let pending = buildPendingSend() else { return }
        store.scheduleSend(pending, at: date)
        close()
    }
}
