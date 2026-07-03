import SwiftUI
import UniformTypeIdentifiers

/// Notion/Gmail-style compose: a docked card with recipient chips,
/// borderless fields, minimal footer.
struct ComposeView: View {
    @EnvironmentObject var store: MailStore

    let replyTo: Message?

    @State private var fromAccount: String = ""
    @State private var toTokens: [String] = []
    @State private var toDraft = ""
    @State private var ccTokens: [String] = []
    @State private var ccDraft = ""
    @State private var showCc = false
    @State private var subject: String = ""
    @State private var body_: String = ""
    @State private var attachmentURLs: [URL] = []
    @State private var showFilePicker = false
    @State private var sending = false
    @State private var drafting = false
    @State private var error: String?
    @FocusState private var bodyFocused: Bool

    private func close() {
        store.composeRequest = nil
    }

    private var hasContent: Bool {
        !body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachmentURLs.isEmpty
    }

    /// Close and keep the work: unsent content becomes a real Gmail draft.
    private func saveAndClose() {
        if hasContent {
            let (from, to, cc, subj, body, reply) =
                (fromAccount, toTokens.joined(separator: ", "), ccTokens.joined(separator: ", "),
                 subject, body_, replyTo)
            Task { await store.saveDraft(from: from, to: to, cc: cc, subject: subj,
                                         body: body, replyTo: reply) }
        }
        close()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: subject as title, close (saves a draft).
            HStack {
                Text(subject.isEmpty ? "New Message" : subject)
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

            // Reply context — you're inside this Gmail thread.
            if let replyTo {
                HStack(spacing: 5) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.system(size: 10))
                    Text("Replying to \(MessageParser.displayName(fromHeader: replyTo.fromHeader)) — same thread in Gmail")
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            }

            // From + Cc toggle row
            HStack {
                Menu {
                    ForEach(store.accounts) { account in
                        Button(menuTitle(account)) { fromAccount = account.id }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text("From").font(.system(size: 12)).foregroundStyle(.tertiary)
                        Text(fromAccount.isEmpty ? "Select account" : fromAccount)
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                if !showCc {
                    Button("Cc") { showCc = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 4)

            TokenAddressField(label: "To", tokens: $toTokens, draft: $toDraft)
                .zIndex(3)
            if showCc || !ccTokens.isEmpty {
                TokenAddressField(label: "Cc", tokens: $ccTokens, draft: $ccDraft)
                    .zIndex(2)
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

            if !attachmentURLs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
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

                if replyTo != nil {
                    footerButton(drafting ? "hourglass" : "sparkles",
                                 help: "Draft with local AI (Ollama)") { draftWithAI() }
                        .disabled(drafting)
                }

                Spacer()

                if hasContent {
                    Button {
                        close()   // discard: no draft
                    } label: {
                        Image(systemName: "trash").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Discard without saving")
                }
                Button("Cancel") { saveAndClose() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(hasContent ? "Close (saves as draft)" : "Close")
                Button {
                    send()
                } label: {
                    Text(sending ? "Sending…" : "Send")
                        .padding(.horizontal, 10)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(sending || fromAccount.isEmpty
                          || (toTokens.isEmpty && !toDraft.contains("@")))
            }
            .padding(.top, 8)
        }
        .padding(14)
        .onAppear { prefill() }
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
        fromAccount = replyTo?.accountId ?? store.accounts.first?.id ?? ""
        if let replyTo {
            toTokens = [MessageParser.emailAddress(replyTo.fromHeader)]
            let subj = replyTo.subject
            subject = subj.lowercased().hasPrefix("re:") ? subj : "Re: \(subj)"
            bodyFocused = true
        }
    }

    private func draftWithAI() {
        guard let replyTo else { return }
        drafting = true
        error = nil
        let intent = body_
        Task {
            do {
                let prompt = Ollama.draftReply(
                    originalFrom: replyTo.fromHeader,
                    originalBody: replyTo.bodyText,
                    intent: intent,
                    userEmail: fromAccount)
                body_ = try await Ollama.generate(prompt: prompt)
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
        for (draft, tokens) in [(toDraft, $toTokens), (ccDraft, $ccTokens)] {
            let cleaned = draft.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            if cleaned.contains("@"), !tokens.wrappedValue.contains(cleaned) {
                tokens.wrappedValue.append(cleaned)
            }
        }
        toDraft = ""; ccDraft = ""
        guard !toTokens.isEmpty else { return }

        sending = true
        error = nil
        Task {
            do {
                var attachments: [MIMEBuilder.Attachment] = []
                for url in attachmentURLs {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                        ?? "application/octet-stream"
                    attachments.append(.init(filename: url.lastPathComponent, mimeType: mime, data: data))
                }
                try await store.send(from: fromAccount,
                                     to: toTokens.joined(separator: ", "),
                                     cc: ccTokens.joined(separator: ", "),
                                     subject: subject, body: body_, replyTo: replyTo,
                                     attachments: attachments)
                close()
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}
