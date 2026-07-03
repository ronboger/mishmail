import SwiftUI
import UniformTypeIdentifiers

struct ComposeView: View {
    @EnvironmentObject var store: MailStore
    @Environment(\.dismiss) private var dismiss

    let replyTo: Message?

    @State private var fromAccount: String = ""
    @State private var to: String = ""
    @State private var cc: String = ""
    @State private var subject: String = ""
    @State private var body_: String = ""
    @State private var attachmentURLs: [URL] = []
    @State private var showFilePicker = false
    @State private var sending = false
    @State private var drafting = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("From", selection: $fromAccount) {
                    ForEach(store.accounts) { Text($0.id).tag($0.id) }
                }
                AddressField(label: "To", text: $to)
                AddressField(label: "Cc", text: $cc)
                TextField("Subject", text: $subject)
            }
            .formStyle(.columns)
            .textFieldStyle(.roundedBorder)
            .padding()

            TextEditor(text: $body_)
                .font(.system(size: 13))
                .padding(.horizontal)
                .frame(minHeight: 220)

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
                    .padding(.horizontal)
                }
                .padding(.bottom, 4)
            }

            HStack {
                Button {
                    showFilePicker = true
                } label: { Image(systemName: "paperclip") }
                    .help("Attach files")

                Menu("Snippets") {
                    let snippets = store.snippets()
                    if snippets.isEmpty { Text("No snippets yet") }
                    ForEach(snippets) { s in
                        Button(s.name) { body_ += s.body }
                    }
                    Divider()
                    Button("Save body as snippet…") { saveCurrentAsSnippet() }
                }
                .frame(width: 110)

                if replyTo != nil {
                    Button {
                        draftWithAI()
                    } label: {
                        Label(drafting ? "Drafting…" : "Draft with AI",
                              systemImage: "sparkles")
                    }
                    .disabled(drafting)
                    .help("Uses a local Ollama model — nothing leaves your Mac")
                }

                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(sending ? "Sending…" : "Send") { send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(sending || to.isEmpty || fromAccount.isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 440)
        .onAppear { prefill() }
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attachmentURLs.append(contentsOf: urls) }
        }
    }

    private func prefill() {
        fromAccount = replyTo?.accountId ?? store.accounts.first?.id ?? ""
        if let replyTo {
            to = MessageParser.emailAddress(replyTo.fromHeader)
            let subj = replyTo.subject
            subject = subj.lowercased().hasPrefix("re:") ? subj : "Re: \(subj)"
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
                let draft = try await Ollama.generate(prompt: prompt)
                body_ = draft
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
                try await store.send(from: fromAccount, to: to, cc: cc,
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
