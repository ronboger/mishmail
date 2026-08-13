import SwiftUI

/// The Ask Mish side panel: transcript, confirm card, and composer.
///
/// All state lives on `AskMishController` (`@Observable`), so the panel is a
/// thin renderer. Two rules the controller enforces silently, and this view
/// must therefore show:
/// - `send`, `newConversation`, `loadConversation`, and `deleteConversation`
///   are no-ops while a turn runs. Every such control is disabled while
///   `controller.isRunning`.
/// - The `send_draft` confirm line comes from `pendingConfirmation.summary`
///   (built from the stored draft), never from the model's arguments.
struct AskMishPanelView: View {
    let controller: AskMishController
    @Environment(MailStore.self) private var store

    @State private var input = ""
    @State private var conversations: [ChatConversationRow] = []
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            if let pending = controller.pendingConfirmation {
                Divider()
                confirmCard(pending)
            }
            Divider()
            composer
        }
        .background(Color.notionSidebar)
        .task { await refreshConversations() }
        // The list is only correct after a turn writes the title / a new row.
        .onChange(of: controller.isRunning) { _, running in
            if !running { Task { await refreshConversations() } }
        }
        .onChange(of: controller.conversationID) {
            Task { await refreshConversations() }
        }
        .onChange(of: store.showAskMish) { _, shown in
            if !shown { declinePendingConfirmation() }
        }
        .onDisappear {
            declinePendingConfirmation()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.notionAccent)
            conversationMenu
            Spacer(minLength: 4)
            modelMenu
            Button {
                store.showAskMish = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close Ask Mish (⌥⌘M)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var currentTitle: String {
        guard let id = controller.conversationID,
              let row = conversations.first(where: { $0.id == id })
        else { return "Ask Mish" }
        return row.title
    }

    private var conversationMenu: some View {
        Menu {
            Button("New chat") { controller.newConversation() }
                .disabled(controller.isRunning)
            if let id = controller.conversationID {
                // Deleting the live conversation would orphan the running
                // turn's writes, so the controller refuses it while running.
                Button("Delete this chat", systemImage: "trash", role: .destructive) {
                    controller.deleteConversation(id: id)
                }
                .disabled(controller.isRunning)
            }
            if !conversations.isEmpty {
                Divider()
                Section("Recent") {
                    ForEach(conversations) { row in
                        Button {
                            controller.loadConversation(id: row.id)
                        } label: {
                            if row.id == controller.conversationID {
                                Label(row.title, systemImage: "checkmark")
                            } else {
                                Text(row.title)
                            }
                        }
                        .disabled(controller.isRunning)
                    }
                }
            }
        } label: {
            Text(currentTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var modelMenu: some View {
        Menu {
            ForEach(LLMProviderStore.load()) { provider in
                Button {
                    controller.providerID = provider.id
                    controller.modelID = provider.defaultModel
                } label: {
                    let title = "\(provider.label) · \(provider.defaultModel)"
                    if provider.id == controller.providerID {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            Text(controller.modelID.isEmpty ? "Pick a model" : controller.modelID)
                .font(.caption)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(controller.isRunning)
        .help("Model for this chat")
    }

    private func declinePendingConfirmation() {
        if controller.pendingConfirmation != nil {
            controller.confirmPendingTool(allow: false)
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if controller.bubbles.isEmpty { emptyState }
                    ForEach(controller.bubbles) { bubble in
                        bubbleView(bubble).id(bubble.id)
                    }
                    // Scroll anchor: a zero-height tail row keeps the newest
                    // bubble fully visible while it grows.
                    Color.clear.frame(height: 1).id(Self.tailID)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: controller.bubbles.count) { scrollToTail(scroller) }
            // Streaming appends to the last bubble without changing the count.
            .onChange(of: controller.bubbles.last?.text) { scrollToTail(scroller) }
        }
        .frame(maxHeight: .infinity)
    }

    private static let tailID = "askmish.tail"

    private func scrollToTail(_ scroller: ScrollViewProxy) {
        scroller.scrollTo(Self.tailID, anchor: .bottom)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask about your mail.")
                .font(.system(size: 13, weight: .medium))
            Text("Try “summarize this thread” or “draft a reply saying yes”.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func bubbleView(_ bubble: AskMishController.Bubble) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if bubble.role == .user {
                Text(bubble.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.notionAccent.opacity(0.16),
                                in: RoundedRectangle(cornerRadius: PMRadius.md))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                if !bubble.text.isEmpty {
                    Text(Self.rendered(bubble.text))
                        .textSelection(.enabled)
                        .foregroundStyle(bubble.isError ? Color.red : Color.primary)
                }
                if bubble.isStreaming { streamingPulse(hasText: !bubble.text.isEmpty) }
                ForEach(Array(bubble.toolCalls.enumerated()), id: \.offset) { _, call in
                    toolCallRow(call)
                }
                if let cost = bubble.costLabel {
                    Text(cost)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if bubble.isError { retryButton }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Markdown, with the plain string as the fallback so a stray `*` in a
    /// half-streamed answer never blanks the bubble.
    private static func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private func streamingPulse(hasText: Bool) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            if !hasText {
                Text("Thinking…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func toolCallRow(_ call: LLMToolCall) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "wrench.and.screwdriver")
            Text(call.name)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.06),
                    in: Capsule())
    }

    /// Re-sends the last user turn. The failed assistant bubble stays, so the
    /// transcript still shows what went wrong.
    private var retryButton: some View {
        Button("Retry") {
            guard let text = controller.bubbles.last(where: { $0.role == .user })?.text
            else { return }
            controller.send(text)
        }
        .buttonStyle(.link)
        .font(.caption)
        .disabled(controller.isRunning
                  || !controller.bubbles.contains { $0.role == .user })
    }

    // MARK: - Confirm card

    private func confirmCard(_ pending: AskMishController.PendingToolConfirmation) -> some View {
        let isSend = pending.toolName == AskMishTools.sendDraftToolName
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield")
                Text(pending.toolName)
                    .font(.caption2.monospaced())
            }
            .foregroundStyle(.secondary)
            // Always the controller's summary: for send_draft it names the
            // resolved recipients and the hidden Bcc count.
            Text(pending.summary)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            if isSend {
                Text("MishMail queues the message. You can undo it for \(Int(MailStore.undoSendWindow)) seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(isSend ? "Send" : "Allow") {
                    controller.confirmPendingTool(allow: true)
                }
                .buttonStyle(.borderedProminent)
                .tint(isSend ? .red : Color.notionAccent)
                // A send needs a real click: the composer is disabled while
                // the card is up, so ↩ would otherwise queue mail from a
                // keystroke meant for the chat.
                .keyboardShortcut(isSend ? nil : KeyboardShortcut.defaultAction)
                Button("Don't allow") {
                    controller.confirmPendingTool(allow: false)
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(12)
        .background(Color.notionContent)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.selectedThread != nil { contextChip }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask Mish…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit(submit)
                    // A send during a run is dropped by the controller, so the
                    // field goes quiet until the turn ends.
                    .disabled(controller.isRunning)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.notionContent,
                                in: RoundedRectangle(cornerRadius: PMRadius.md))
                if controller.isRunning {
                    Button {
                        controller.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .help("Stop")
                } else {
                    Button {
                        submit()
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send (↩)")
                }
            }
            if let cost = controller.conversationCostLabel {
                Text(cost)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(12)
    }

    private var contextChip: some View {
        Button {
            controller.includeSelectedThread.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: controller.includeSelectedThread ? "xmark" : "plus")
                Text(controller.includeSelectedThread ? "Current thread" : "Add current thread")
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(controller.includeSelectedThread
                        ? Color.notionAccent.opacity(0.16)
                        : Color.primary.opacity(0.06),
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .help(controller.includeSelectedThread
              ? "Stop sending the open conversation"
              : "Send the open conversation with your next question")
    }

    private func submit() {
        let text = input
        guard !controller.isRunning,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        controller.send(text)
        input = ""
    }

    private func refreshConversations() async {
        conversations = await controller.listConversations()
    }
}
