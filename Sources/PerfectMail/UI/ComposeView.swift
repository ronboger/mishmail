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
    @State private var attachmentURLs: [URL] = []
    /// Attachments carried back from an undone send (data already loaded).
    @State private var restoredAttachments: [MIMEBuilder.Attachment] = []
    @State private var showFilePicker = false
    @State private var drafting = false
    @State private var error: String?
    @FocusState private var bodyFocused: Bool

    @State private var initialBody = ""
    @State private var initialSubject = ""
    @State private var initialRecipients: [String] = []

    private func close() {
        store.composeRequest = nil
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
            || !restoredAttachments.isEmpty
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
            let (from, to, cc, bcc, subj, body, reply, old) =
                (fromAccount, toTokens.joined(separator: ", "), ccTokens.joined(separator: ", "),
                 bccTokens.joined(separator: ", "), subject, body_, replyTo, editingDraft)
            Task { await store.saveDraft(from: from, to: to, cc: cc, bcc: bcc, subject: subj,
                                         body: body, replyTo: reply, replacing: old) }
        }
        close()
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
                         : "Replying to \(MessageParser.displayName(fromHeader: original.fromHeader)) — same thread in Gmail")
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
                              autoFocus: original == nil && editingDraft == nil)
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
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .focused($bodyFocused)
                .padding(.top, 8)
                .frame(minHeight: 120, maxHeight: .infinity)

            if !attachmentURLs.isEmpty || !restoredAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
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

            HStack(spacing: 10) {
                footerButton("paperclip", help: "Attach files") { showFilePicker = true }

                Menu {
                    let snippets = store.snippets()
                    if snippets.isEmpty { Text("No snippets yet") }
                    ForEach(snippets) { s in
                        Button(s.name) { body_ += s.body }
                    }
                    Divider()
                    Button("Save body as snippet…") { saveCurrentAsSnippet() }
                } label: {
                    Image(systemName: "text.badge.plus")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Snippets")

                if original != nil, !request.forward {
                    footerButton(drafting ? "hourglass" : "sparkles",
                                 help: "Draft with local AI (Ollama)") { draftWithAI() }
                        .disabled(drafting)
                }

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
                Button {
                    send()
                } label: {
                    Text("Send")
                        .padding(.horizontal, 10)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .help("Send (10s undo window)")
                .disabled(fromAccount.isEmpty
                          || (toTokens.isEmpty && !toDraft.contains("@")
                              && bccTokens.isEmpty && !bccDraft.contains("@")))
            }
            .padding(.top, 8)
        }
        .padding(14)
        .onAppear { prefill() }
        .onChange(of: store.accounts) {
            // Accounts can finish loading after the card appears — backfill From.
            if fromAccount.isEmpty {
                fromAccount = store.activeAccountId ?? store.accounts.first?.id ?? ""
            }
        }
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attachmentURLs.append(contentsOf: urls) }
        }
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
            bodyFocused = true
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
            bodyFocused = true
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
        guard let original else { return }
        let ownAddresses = Set(store.accounts.map { $0.id.lowercased() })
        let sender = MessageParser.emailAddress(original.fromHeader)

        if request.forward {
            let subj = original.subject
            subject = subj.lowercased().hasPrefix("fwd:") ? subj : "Fwd: \(subj)"
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

        // Quote the previous message so the context travels with the draft.
        let when = original.date.formatted(date: .abbreviated, time: .shortened)
        let who = "\(MessageParser.displayName(fromHeader: original.fromHeader)) <\(sender)>"
        let quoted = original.bodyText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        body_ = "\n\n\nOn \(when), \(who) wrote:\n\(quoted)"
        initialBody = body_
        bodyFocused = true
    }

    private func draftWithAI() {
        guard let original else { return }
        drafting = true
        error = nil
        // Only the part above the quote counts as intent.
        let intent = String(body_.split(separator: "\nOn ", maxSplits: 1,
                                        omittingEmptySubsequences: false).first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let prompt = Ollama.draftReply(
                    originalFrom: original.fromHeader,
                    originalBody: original.bodyText,
                    intent: intent,
                    userEmail: fromAccount)
                let draft = try await Ollama.generate(prompt: prompt)
                // Keep the quoted context below the AI draft.
                let quoteStart = body_.range(of: "\nOn ")
                let quote = quoteStart.map { String(body_[$0.lowerBound...]) } ?? ""
                body_ = draft + "\n" + quote
            } catch {
                self.error = error.localizedDescription
            }
            drafting = false
        }
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

    private func send() {
        // Typed-but-uncommitted addresses count as recipients.
        for (draft, tokens) in [(toDraft, $toTokens), (ccDraft, $ccTokens), (bccDraft, $bccTokens)] {
            let cleaned = draft.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            if cleaned.contains("@"), !tokens.wrappedValue.contains(cleaned) {
                tokens.wrappedValue.append(cleaned)
            }
        }
        toDraft = ""; ccDraft = ""; bccDraft = ""
        guard !toTokens.isEmpty || !bccTokens.isEmpty else { return }

        error = nil
        do {
            // Load attachment data now — the compose card closes immediately
            // and the actual send happens after the undo window.
            var attachments = restoredAttachments
            for url in attachmentURLs {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                    ?? "application/octet-stream"
                attachments.append(.init(filename: url.lastPathComponent, mimeType: mime, data: data))
            }
            store.queueSend(MailStore.PendingSend(
                accountId: fromAccount,
                to: toTokens.joined(separator: ", "),
                cc: ccTokens.joined(separator: ", "),
                bcc: bccTokens.joined(separator: ", "),
                subject: subject, body: body_,
                replyTo: replyTo, forward: request.forward,
                attachments: attachments,
                replacingDraft: editingDraft))
            close()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
