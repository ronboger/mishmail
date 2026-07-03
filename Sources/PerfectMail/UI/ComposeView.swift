import SwiftUI
import UniformTypeIdentifiers

/// Notion Mail-style compose: chips for recipients, borderless fields,
/// minimal footer.
struct ComposeView: View {
    @EnvironmentObject var store: MailStore
    @Environment(\.dismiss) private var dismiss

    let replyTo: Message?

    @State private var fromAccount: String = ""
    @State private var toTokens: [String] = []
    @State private var ccTokens: [String] = []
    @State private var showCc = false
    @State private var subject: String = ""
    @State private var body_: String = ""
    @State private var attachmentURLs: [URL] = []
    @State private var showFilePicker = false
    @State private var sending = false
    @State private var drafting = false
    @State private var error: String?
    @FocusState private var bodyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // From + Cc toggle row
            HStack {
                Menu {
                    ForEach(store.accounts) { account in
                        Button(account.id) { fromAccount = account.id }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(fromAccount.isEmpty ? "From" : fromAccount)
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8)).foregroundStyle(.secondary)
                    }
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

            TokenAddressField(label: "To", tokens: $toTokens)
            if showCc || !ccTokens.isEmpty {
                TokenAddressField(label: "Cc", tokens: $ccTokens)
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
                .frame(minHeight: 200, maxHeight: .infinity)

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

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Button {
                    send()
                } label: {
                    Text(sending ? "Sending…" : "Send")
                        .padding(.horizontal, 10)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(sending || toTokens.isEmpty || fromAccount.isEmpty)
            }
            .padding(.top, 8)
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 460)
        .onAppear { prefill() }
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attachmentURLs.append(contentsOf: urls) }
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
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}
