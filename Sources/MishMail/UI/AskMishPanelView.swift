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
    @State private var showAttachPopover = false
    @State private var attachQuery = ""
    @State private var attachResults: [AskMishController.AttachedThread] = []
    /// Installed-and-enabled Ollama models for the model menu. The stored
    /// provider row does not track what `ollama pull` added or the Settings
    /// toggles turned off, so the panel asks the live endpoint once.
    @State private var localModels: [String] = []
    @State private var modelPickerShown = false
    @State private var expandedThinking: Set<UUID> = []

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
        .task {
            let installed = (try? await Ollama.installedModels()) ?? []
            localModels = Ollama.enabledModels(installed: installed)
        }
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
        Button {
            modelPickerShown = true
        } label: {
            HStack(spacing: 4) {
                Text(controller.modelID.isEmpty ? "Pick a model" : controller.modelID)
                    .font(.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            // Small label, comfortable target.
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controller.isRunning)
        .help("Model for this chat")
        // The panel hugs the window's right edge, so the picker opens to the
        // side (leftward), not downward over the transcript.
        .popover(isPresented: $modelPickerShown, arrowEdge: .leading) {
            ModelPickerPopover(
                localModels: localModels,
                currentProviderID: controller.providerID,
                currentModelID: controller.modelID,
                onPick: { providerID, model in
                    let previous = controller.modelID
                    let wasLocal = controller.providerID == LLMProviderStore.builtInOllamaID
                    controller.providerID = providerID
                    controller.modelID = model
                    modelPickerShown = false
                    // Switching away from a local model leaves its weights in
                    // Ollama for the whole keep_alive window. Nothing will use
                    // them, so drop them now.
                    if wasLocal, previous != model {
                        Task { await Ollama.unload(model: previous) }
                    }
                },
                onSetDefault: { provider, model in
                    setDefaultModel(model, for: provider)
                },
                onTogglePin: { provider, model in
                    togglePin(model, for: provider)
                })
        }
    }

    /// Saves `model` as the provider's default and points the Ask Mish task
    /// assignment at it, so the provider row's one-click pick and every new
    /// chat use it. The current chat keeps its own selection untouched.
    private func setDefaultModel(_ model: String, for provider: LLMProviderConfig) {
        var list = LLMProviderStore.load()
        guard let index = list.firstIndex(where: { $0.id == provider.id }) else { return }
        list[index].defaultModel = model
        LLMProviderStore.save(list)
        LLMProviderStore.setAssignment(
            LLMTaskAssignment(providerID: provider.id, model: model), for: .askMish)
    }

    /// Adds or removes a model from the provider's pin list. Pinned models
    /// are what the picker's browse column shows.
    private func togglePin(_ model: String, for provider: LLMProviderConfig) {
        var list = LLMProviderStore.load()
        guard let index = list.firstIndex(where: { $0.id == provider.id }) else { return }
        var pins = list[index].pinnedModels ?? []
        if let existing = pins.firstIndex(of: model) {
            pins.remove(at: existing)
        } else {
            pins.append(model)
        }
        list[index].pinnedModels = pins.isEmpty ? nil : pins
        LLMProviderStore.save(list)
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
                if !bubble.reasoningText.isEmpty {
                    thinkingDisclosure(bubble)
                }
                if !bubble.text.isEmpty {
                    Text(Self.rendered(bubble.text))
                        .textSelection(.enabled)
                        .foregroundStyle(bubble.isError ? Color.red : Color.primary)
                }
                if bubble.isStreaming { streamingPulse(hasText: !bubble.text.isEmpty) }
                ForEach(Array(bubble.toolCalls.enumerated()), id: \.offset) { _, call in
                    toolCallRow(call)
                }
                // Tool-only turns skip the per-turn label: an agent loop that
                // searches five times would stack five bare token lines above
                // the answer. The conversation total still counts them.
                if let cost = bubble.costLabel, !bubble.text.isEmpty {
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

    /// Collapsed thinking trace. While the model is still reasoning (no
    /// visible text yet) the row pulses "Thinking"; expanding shows the trace.
    private func thinkingDisclosure(_ bubble: AskMishController.Bubble) -> some View {
        let expanded = expandedThinking.contains(bubble.id)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    if expanded { expandedThinking.remove(bubble.id) }
                    else { expandedThinking.insert(bubble.id) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                        .font(.system(size: 9))
                    Text(bubble.isStreaming && bubble.text.isEmpty ? "Thinking…" : "Thought process")
                        .font(.caption2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(bubble.reasoningText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: PMRadius.sm))
            }
        }
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
            attachmentRow
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

    // MARK: - Attachments

    /// Context chips: the open thread, pinned threads, and the attach button.
    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if store.selectedThread != nil { contextChip }
                ForEach(controller.attachedThreads) { attached in
                    attachedChip(attached)
                }
                attachButton
            }
        }
    }

    private func attachedChip(_ attached: AskMishController.AttachedThread) -> some View {
        Button {
            controller.detachThread(id: attached.id)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "xmark")
                Text(attached.subject.isEmpty ? "(no subject)" : attached.subject)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 160)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.notionAccent.opacity(0.16), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Stop sending this conversation")
    }

    private var attachButton: some View {
        Button {
            showAttachPopover = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                Text("Attach")
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Search for a conversation to attach")
        .popover(isPresented: $showAttachPopover, arrowEdge: .top) {
            attachSearch
        }
    }

    private var attachSearch: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search conversations…", text: $attachQuery)
                .textFieldStyle(.roundedBorder)
            if attachResults.isEmpty {
                Text(attachQuery.count >= ThreadTypeahead.minimumQueryLength
                     ? "No matches." : "Type to search your mail.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(attachResults) { row in
                Button {
                    controller.attachThread(id: row.id, subject: row.subject)
                    showAttachPopover = false
                    attachQuery = ""
                    attachResults = []
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "text.bubble")
                            .foregroundStyle(.secondary)
                        Text(row.subject.isEmpty ? "(no subject)" : row.subject)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(controller.attachedThreads.contains { $0.id == row.id })
            }
        }
        .padding(12)
        .frame(width: 280)
        .task(id: attachQuery) {
            attachResults = await controller.searchThreadsToAttach(query: attachQuery)
        }
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

/// A provider's brand mark (vendored monochrome template asset) at a fixed
/// footprint, tinted like secondary text; SF-symbol fallback for providers
/// without a mark.
private struct ProviderIcon: View {
    let provider: LLMProviderConfig
    var size: CGFloat = 13

    var body: some View {
        Group {
            if let asset = AskMishModelMenu.brandAsset(for: provider) {
                Image(asset)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: AskMishModelMenu.fallbackIcon)
                    .font(.system(size: size - 1))
            }
        }
        .foregroundStyle(.secondary)
        .frame(width: 16)
    }
}

/// Aside-style model picker: search on top, one row per provider with an
/// icon; hovering or clicking a provider flies its model list out in a second
/// column to the side, like a native submenu. Typing switches to a flat
/// filtered list over the FULL stored model lists, so curation never hides a
/// model from search.
private struct ModelPickerPopover: View {
    let localModels: [String]
    let currentProviderID: UUID
    let currentModelID: String
    let onPick: (UUID, String) -> Void
    let onSetDefault: (LLMProviderConfig, String) -> Void
    let onTogglePin: (LLMProviderConfig, String) -> Void

    /// Snapshot of the store, re-read after every default/pin mutation so the
    /// open popover reflects it immediately.
    @State private var providers: [LLMProviderConfig] = []
    @State private var query = ""
    @State private var expandedProviderID: UUID?
    @FocusState private var searchFocused: Bool

    private func mutate(_ action: () -> Void) {
        action()
        providers = LLMProviderStore.load()
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var expandedProvider: LLMProviderConfig? {
        guard !isSearching, let id = expandedProviderID else { return nil }
        return providers.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Search models", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if isSearching {
                            searchResults
                        } else {
                            ForEach(providers) { provider in providerRow(provider) }
                        }
                    }
                    .padding(6)
                }
                .frame(width: 220)
                // The flyout: the expanded provider's models, to the side.
                if let provider = expandedProvider {
                    Divider()
                    modelColumn(provider)
                        .frame(width: 210)
                        .transition(.opacity)
                }
            }
            .frame(maxHeight: 320)
        }
        .fixedSize(horizontal: true, vertical: false)
        .onAppear {
            providers = LLMProviderStore.load()
            expandedProviderID = currentProviderID
            searchFocused = true
        }
    }

    // MARK: - Browse mode

    /// Ollama rows list the live installed-and-enabled models; other rows the
    /// stored (curated) list.
    private func listedModels(_ provider: LLMProviderConfig) -> AskMishModelMenu.ProviderModels {
        var listed = provider
        if provider.kind == .ollama, !localModels.isEmpty {
            listed.models = localModels
        }
        let isCurrent = provider.id == currentProviderID
        return AskMishModelMenu.models(for: listed, selected: isCurrent ? currentModelID : nil)
    }

    private func providerRow(_ provider: LLMProviderConfig) -> some View {
        let expanded = expandedProviderID == provider.id
        return Button {
            expandedProviderID = provider.id
        } label: {
            HStack(spacing: 8) {
                ProviderIcon(provider: provider, size: 13)
                Text(provider.label)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                if provider.id == currentProviderID {
                    Circle().fill(Color.notionAccent).frame(width: 5, height: 5)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(expanded ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: PMRadius.sm))
        .onHover { hovering in
            if hovering { expandedProviderID = provider.id }
        }
    }

    private func modelColumn(_ provider: LLMProviderConfig) -> some View {
        let entry = listedModels(provider)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(entry.models, id: \.self) { model in
                    modelRow(provider: provider, model: model)
                }
                if entry.hiddenCount > 0 {
                    Text("\(entry.hiddenCount) more — search above")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                }
                Text("Right-click a model to pin it here")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }
            .padding(6)
        }
    }

    private func modelRow(provider: LLMProviderConfig, model: String) -> some View {
        let isSelected = provider.id == currentProviderID && model == currentModelID
        let isDefault = model == provider.defaultModel
        let isPinned = (provider.pinnedModels ?? []).contains(model)
        let title = AskMishModelMenu.displayName(model)
        return Button {
            onPick(provider.id, model)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // Routed ids keep the vendor prefix visible as a subtitle.
                    if title != model {
                        Text(model)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                if isDefault {
                    Text("default")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.notionAccent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model)
        .background(isSelected ? Color.notionAccent.opacity(0.10) : .clear,
                    in: RoundedRectangle(cornerRadius: PMRadius.sm))
        .contextMenu { modelActions(provider: provider, model: model,
                                    isDefault: isDefault, isPinned: isPinned) }
    }

    @ViewBuilder
    private func modelActions(provider: LLMProviderConfig, model: String,
                              isDefault: Bool, isPinned: Bool) -> some View {
        Button(isPinned ? "Unpin" : "Pin to \(provider.label)") {
            mutate { onTogglePin(provider, model) }
        }
        if !isDefault {
            Button("Set as default for \(provider.label)") {
                mutate { onSetDefault(provider, model) }
            }
        }
    }

    // MARK: - Search mode

    @ViewBuilder
    private var searchResults: some View {
        let hits = AskMishModelMenu.search(providers: providers, query: query)
        if hits.isEmpty {
            Text("No models match “\(query)”.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        ForEach(hits) { hit in
            if let provider = providers.first(where: { $0.id == hit.providerID }) {
                Button {
                    onPick(hit.providerID, hit.model)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        ProviderIcon(provider: provider, size: 12)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(AskMishModelMenu.displayName(hit.model))
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if AskMishModelMenu.displayName(hit.model) != hit.model {
                                Text(hit.model)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        Spacer(minLength: 4)
                        Text(hit.providerLabel)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(hit.model)
                .contextMenu {
                    modelActions(provider: provider, model: hit.model,
                                 isDefault: hit.model == provider.defaultModel,
                                 isPinned: (provider.pinnedModels ?? []).contains(hit.model))
                }
            }
        }
    }
}
