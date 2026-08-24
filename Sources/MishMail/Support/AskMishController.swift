import Foundation
import GRDB
import Observation

/// The Ask Mish agent loop: one user turn in, streamed assistant text and
/// tool round-trips out, until the model answers or the tool cap is hit.
///
/// App-target only (it owns a `MailStore` and touches the shared database).
/// Every pure piece it leans on is tested elsewhere: prompt and history
/// assembly in `AskMishContext`, the tool surface in `AskMishTools`, cost
/// labels in `LLMPricing`, tool execution in `MCPRouter`.
///
/// Two rules shape the persistence here:
/// - An assistant row and its tool-results row are written **together**, in one
///   transaction, with exactly one `LLMToolResult` per tool call id.
///   `AskMishContext.llmMessages` drops any turn whose ids do not match, so a
///   half-written turn would silently vanish on reload.
/// - All tool results of one assistant turn go into **one** `.tool` message.
///   Anthropic requires strictly alternating roles.
@MainActor
@Observable
final class AskMishController {

    /// One rendered row in the transcript. Tool results are not shown as
    /// bubbles; a call appears on the assistant bubble that requested it.
    struct Bubble: Identifiable {
        let id: UUID
        var role: LLMRole
        var text: String
        /// The model's thinking trace, when it emits one. Rendered collapsed;
        /// transient — not persisted with the conversation.
        var reasoningText: String = ""
        var toolCalls: [LLMToolCall] = []
        var costLabel: String? = nil
        var isStreaming: Bool = false
        var isError: Bool = false
    }

    /// A write tool waiting for the user. The loop is parked on a continuation
    /// until `confirmPendingTool(allow:)` resolves it.
    struct PendingToolConfirmation: Identifiable {
        let id: UUID
        let toolName: String
        /// One short user-facing line. For `send_draft` this comes from the
        /// resolved draft, not from the model's arguments.
        let summary: String
        let argumentsJSON: String
        /// Draft body shown on the card. Nil when the tool has no body.
        var bodyPreview: String? = nil
        /// True for create_draft / send_draft: Return must not confirm.
        var requiresExplicitClick: Bool = false
        /// Snapshot of the draft at confirm time. Send aborts if it drifts.
        var sendFingerprint: String? = nil
    }

    // MARK: - Rendered state

    private(set) var bubbles: [Bubble] = []
    private(set) var isRunning = false
    private(set) var conversationID: String?
    private(set) var pendingConfirmation: PendingToolConfirmation?

    /// Context chip: send the open thread with the conversation. On by default —
    /// "summarize this" is the common ask.
    var includeSelectedThread = true

    /// A thread the user pinned to the conversation from the attach popover.
    struct AttachedThread: Identifiable, Equatable {
        let id: String
        let subject: String
    }

    /// Threads pinned beyond the open one. Each goes into the history once,
    /// on the next user turn.
    private(set) var attachedThreads: [AttachedThread] = []

    /// Model choice for this conversation. Defaults from the per-task
    /// assignment; persisted on the conversation row.
    var providerID: UUID
    var modelID: String

    /// Running token/cost total for the whole conversation. Nil until a turn
    /// reports usage (local models often report none).
    private(set) var conversationCostLabel: String?

    // MARK: - Internals

    private weak var store: MailStore?
    private let bridge: MCPBridge

    @ObservationIgnored private var turnTask: Task<Void, Never>?
    @ObservationIgnored private var confirmContinuation: CheckedContinuation<Bool, Never>?
    /// Wire history for this conversation, including the injected thread
    /// context. Rebuilt from the database on `loadConversation`.
    @ObservationIgnored private var history: [LLMMessage] = []
    /// Threads whose markdown is already in `history`, so each context goes in
    /// once per conversation instead of on every turn.
    @ObservationIgnored private var injectedThreadIDs: Set<String> = []
    @ObservationIgnored private var totalPromptTokens = 0
    @ObservationIgnored private var totalCompletionTokens = 0

    init(store: MailStore) {
        self.store = store
        self.bridge = MCPBridge(store: store)
        let assignment = LLMProviderStore.assignment(for: .askMish)
        self.providerID = assignment.providerID
        self.modelID = assignment.model
    }

    // MARK: - Turn lifecycle

    /// Starts one user turn. Ignored while a turn is running or the text is blank.
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !trimmed.isEmpty else { return }
        isRunning = true
        turnTask = Task { [weak self] in
            await self?.runTurn(userText: trimmed)
            self?.isRunning = false
        }
    }

    /// Cancels the in-flight turn. A parked confirm card counts as declined,
    /// otherwise the loop would wait for an answer that can no longer come.
    func stop() {
        resolvePendingConfirmation(allow: false)
        turnTask?.cancel()
    }

    func confirmPendingTool(allow: Bool) {
        resolvePendingConfirmation(allow: allow)
    }

    /// Longest the quit path waits for a cancelled turn to unwind.
    private static let shutdownWaitSeconds: Double = 3

    /// Holds the "the turn finished" bit for the bounded wait below. A captured
    /// local `var` cannot be written from another task.
    @MainActor private final class DoneFlag { var isSet = false }

    /// Cancel and await the in-flight turn. Called from
    /// `MailStore.executeTermination` before the database pool closes.
    ///
    /// The wait is **bounded**. Declining the parked confirm card and
    /// cancelling the task releases every stage that checks cancellation, but a
    /// tool call already inside `MCPRouter` (an IMAP or HTTP round-trip) may not
    /// observe it, and an unbounded `await turnTask?.value` then stalls the
    /// whole quit path — the failure mode the app has hit before. After
    /// `shutdownWaitSeconds` we stop waiting and let termination continue: an
    /// orphaned request can only fail harmlessly once the pool closes.
    func shutdown() async {
        resolvePendingConfirmation(allow: false)
        turnTask?.cancel()
        if let task = turnTask {
            let flag = DoneFlag()
            let waiter = Task { @MainActor in
                _ = await task.value
                flag.isSet = true
            }
            let deadline = Date().addingTimeInterval(Self.shutdownWaitSeconds)
            while !flag.isSet, Date() < deadline, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            waiter.cancel()
        }
        turnTask = nil
        isRunning = false
    }

    private func resolvePendingConfirmation(allow: Bool) {
        pendingConfirmation = nil
        confirmContinuation?.resume(returning: allow)
        confirmContinuation = nil
    }

    // MARK: - Conversations

    /// Clears the panel. The old conversation stays on disk.
    func newConversation() {
        guard !isRunning else { return }
        conversationID = nil
        bubbles = []
        history = []
        injectedThreadIDs = []
        attachedThreads = []
        totalPromptTokens = 0
        totalCompletionTokens = 0
        conversationCostLabel = nil
    }

    /// Reloads a stored conversation into the panel.
    func loadConversation(id: String) {
        guard !isRunning else { return }
        let rows = (try? AppDatabase.shared.dbPool.read { db in
            try ChatMessageRow
                .filter(Column("conversationId") == id)
                .order(Column("createdAt"), Column("id"))
                .fetchAll(db)
        }) ?? []
        let conversation = try? AppDatabase.shared.dbPool.read { db in
            try ChatConversationRow.fetchOne(db, key: id)
        }
        conversationID = id
        if let conversation, let storedProvider = UUID(uuidString: conversation.providerID) {
            providerID = storedProvider
            modelID = conversation.modelID
        }
        // The thread context is deliberately not persisted: it is a snapshot of
        // whatever was open, and it would show up as a wall of quoted mail in
        // the transcript. It goes in again on the next turn.
        history = AskMishContext.llmMessages(history: rows)
        injectedThreadIDs = []
        attachedThreads = []
        totalPromptTokens = rows.reduce(0) { $0 + ($1.promptTokens ?? 0) }
        totalCompletionTokens = rows.reduce(0) { $0 + ($1.completionTokens ?? 0) }
        bubbles = reloadedBubbles(from: rows)
        conversationCostLabel = totalCostLabel()
    }

    /// Newest first, for the conversation picker.
    func listConversations() async -> [ChatConversationRow] {
        let rows = try? await AppDatabase.shared.dbPool.read { db in
            try ChatConversationRow
                .order(Column("updatedAt").desc)
                .limit(200)
                .fetchAll(db)
        }
        return rows ?? []
    }

    /// Deletes a conversation and its messages. Clears the panel when it is
    /// the one on screen.
    ///
    /// Refused while a turn is running: deleting the live conversation would
    /// leave `conversationID` pointing at a deleted row, and the turn's next
    /// write would fail the foreign key. The UI disables the control instead.
    func deleteConversation(id: String) {
        guard !isRunning else { return }
        _ = try? AppDatabase.shared.dbPool.write { db in
            try ChatConversationRow.deleteOne(db, key: id)
        }
        if conversationID == id { newConversation() }
    }

    /// Rebuilds the transcript from stored rows. Tool rows carry no text worth
    /// showing, so they are skipped; an assistant row keeps its tool calls.
    private func reloadedBubbles(from rows: [ChatMessageRow]) -> [Bubble] {
        let config = currentProviderConfig()
        let overrides = LLMPricing.loadOverrides()
        return rows.compactMap { row in
            guard let role = LLMRole(rawValue: row.role), role == .user || role == .assistant
            else { return nil }
            let calls = (try? JSONDecoder().decode(
                [LLMToolCall].self, from: Data(row.toolCallsJSON.utf8))) ?? []
            if row.text.isEmpty, calls.isEmpty { return nil }
            // Stored tokens rebuild the per-turn label, so a reloaded
            // transcript still shows what each turn cost.
            var label: String?
            if let config, let prompt = row.promptTokens, let completion = row.completionTokens {
                label = LLMPricing.costLabel(
                    usage: LLMUsage(promptTokens: prompt, completionTokens: completion),
                    config: config, model: modelID, overrides: overrides)
            }
            return Bubble(id: UUID(uuidString: row.id) ?? UUID(),
                          role: role, text: row.text, toolCalls: calls, costLabel: label)
        }
    }

    // MARK: - The loop

    private func runTurn(userText: String) async {
        guard let config = currentProviderConfig() else {
            appendError("No model is set up. Pick one in Settings → AI.")
            return
        }
        let overrides = LLMPricing.loadOverrides()
        await ensureConversation(firstUserText: userText)
        await appendUser(userText)
        let tools = AskMishTools.llmToolSpecs()

        for _ in 0..<AskMishContext.maxToolTurnsPerUserTurn {
            var streamedText = ""
            var calls: [LLMToolCall] = []
            var usage: LLMUsage?
            let bubbleID = beginAssistantBubble()
            let request = [systemMessage()] + AskMishContext.prepareForModel(history)
            do {
                for try await event in await LLMClient.shared.stream(
                    messages: request, tools: tools, config: config, model: modelID,
                    task: .askMish) {
                    switch event {
                    case .token(let token):
                        streamedText += token
                        updateBubble(bubbleID, text: streamedText)
                    case .reasoning(let trace):
                        appendReasoning(bubbleID, trace)
                    case .toolCall(let call):
                        calls.append(call)
                    case .done(_, let reported):
                        usage = reported
                    }
                }
            } catch is CancellationError {
                // Keep the partial answer, drop the unanswered calls: a stored
                // tool_use without results makes the whole turn unusable.
                markInterrupted(bubbleID)
                await persistTurn(assistantText: streamedText, calls: [],
                                  results: nil, usage: usage)
                appendToHistory(assistantText: streamedText, calls: [])
                return
            } catch {
                markError(bubbleID, error.localizedDescription)
                return
            }
            if Task.isCancelled {
                markInterrupted(bubbleID)
                await persistTurn(assistantText: streamedText, calls: [],
                                  results: nil, usage: usage)
                appendToHistory(assistantText: streamedText, calls: [])
                return
            }
            addUsage(usage)
            let turnCost = LLMPricing.costLabel(usage: usage, config: config,
                                                model: modelID, overrides: overrides)
            finishBubble(bubbleID, costLabel: turnCost)
            conversationCostLabel = totalCostLabel()

            guard !calls.isEmpty else {
                // No text and no calls: the stream ended without an answer.
                // Treat it as a failure, not as a finished turn.
                if streamedText.isEmpty {
                    markError(bubbleID, "The model returned nothing. Try again.")
                    return
                }
                await persistTurn(assistantText: streamedText, calls: [],
                                  results: nil, usage: usage)
                appendToHistory(assistantText: streamedText, calls: [])
                return
            }

            // Run every call, then persist the assistant row and its single
            // tool row in one write. A cancel part-way still answers each
            // remaining call, so the stored ids stay balanced.
            var results: [LLMToolResult] = []
            for call in calls {
                if Task.isCancelled {
                    results.append(LLMToolResult(
                        callID: call.id, content: "Stopped before this ran.", isError: true))
                    continue
                }
                results.append(await execute(call))
            }
            await persistTurn(assistantText: streamedText, calls: calls,
                              results: results, usage: usage)
            appendToHistory(assistantText: streamedText, calls: calls, results: results)
            if Task.isCancelled {
                markInterrupted(bubbleID)
                return
            }
        }
        appendError("Stopped after \(AskMishContext.maxToolTurnsPerUserTurn) tool calls. Ask again to continue.")
    }

    /// Runs one tool call, gating writes behind the confirm card.
    private func execute(_ call: LLMToolCall) async -> LLMToolResult {
        var sendFingerprint: String?
        if AskMishTools.isWriteTool(call.name) {
            switch await requestConfirmation(for: call) {
            case .declined:
                return LLMToolResult(callID: call.id,
                                     content: "The user declined this action.", isError: true)
            case .unavailable(let message):
                return LLMToolResult(callID: call.id, content: message, isError: true)
            case .allowed(let fingerprint):
                sendFingerprint = fingerprint
            }
        }
        do {
            let args = try AskMishTools.decodeArguments(call.argumentsJSON)
            // `send_draft` is Ask Mish-only: MCPRouter throws unknownTool for it
            // by design, so it must branch before dispatch.
            if call.name == AskMishTools.sendDraftToolName {
                guard let store else {
                    return LLMToolResult(callID: call.id,
                                         content: "MishMail is closing.", isError: true)
                }
                guard case .string(let draftId)? = args["draft_id"] else {
                    return LLMToolResult(callID: call.id,
                                         content: "draft_id is required", isError: true)
                }
                let receipt = try await store.askMishSendDraft(
                    draftId: draftId,
                    expectedFingerprint: sendFingerprint)
                return LLMToolResult(callID: call.id, content: receipt, isError: false)
            }
            let text = try await MCPRouter.dispatch(name: call.name, args: args, tools: bridge)
            return LLMToolResult(callID: call.id, content: text, isError: false)
        } catch let error as MCPRouter.ToolDispatchError {
            return LLMToolResult(callID: call.id, content: Self.message(for: error), isError: true)
        } catch {
            return LLMToolResult(callID: call.id, content: error.localizedDescription, isError: true)
        }
    }

    private static func message(for error: MCPRouter.ToolDispatchError) -> String {
        switch error {
        case .unknownTool: return "Unknown tool."
        case .invalidParams(let message): return message
        case .execution(let message): return message
        }
    }

    private enum ConfirmDecision {
        case allowed(sendFingerprint: String?)
        case declined
        case unavailable(String)
    }

    /// Shows the confirm card and parks until the user answers.
    private func requestConfirmation(for call: LLMToolCall) async -> ConfirmDecision {
        if Task.isCancelled { return .declined }
        let fallback = AskMishTools.confirmContent(
            toolName: call.name, argumentsJSON: call.argumentsJSON)
        var summary = fallback.summary
        var bodyPreview = fallback.bodyPreview
        var fingerprint: String?
        // Send must resolve the stored draft. A missing draft used to fall
        // back to a one-line card and then send with no fingerprint.
        if call.name == AskMishTools.sendDraftToolName {
            guard let store else {
                return .unavailable("MishMail is closing.")
            }
            guard let args = try? AskMishTools.decodeArguments(call.argumentsJSON),
                  case .string(let draftId)? = args["draft_id"],
                  let preview = await store.askMishSendConfirmPreview(draftId: draftId)
            else {
                return .unavailable("Draft not found. Confirm again after the draft exists.")
            }
            summary = preview.summary
            bodyPreview = preview.bodyPreview
            fingerprint = preview.fingerprint
        }
        if Task.isCancelled { return .declined }
        pendingConfirmation = PendingToolConfirmation(
            id: UUID(), toolName: call.name, summary: summary,
            argumentsJSON: call.argumentsJSON,
            bodyPreview: bodyPreview,
            requiresExplicitClick: fallback.requiresExplicitClick,
            sendFingerprint: fingerprint)
        let allowed = await withCheckedContinuation { continuation in
            confirmContinuation = continuation
        }
        return allowed ? .allowed(sendFingerprint: fingerprint) : .declined
    }

    // MARK: - Message assembly

    private func currentProviderConfig() -> LLMProviderConfig? {
        LLMProviderStore.load().first { $0.id == providerID }
    }

    /// Hosted models send mail text off this Mac. The panel shows a one-time
    /// notice per provider until the user dismisses it.
    var showsHostedNotice: Bool {
        guard let config = currentProviderConfig(),
              LLMRemotePolicy.sendsMailOffDevice(config) else { return false }
        return !UserDefaults.standard.bool(forKey: Self.hostedAckKey(config.id))
    }

    func acknowledgeHostedNotice() {
        guard let config = currentProviderConfig() else { return }
        UserDefaults.standard.set(true, forKey: Self.hostedAckKey(config.id))
    }

    private static func hostedAckKey(_ id: UUID) -> String {
        "askMish.hostedAck.\(id.uuidString)"
    }

    private func systemMessage() -> LLMMessage {
        LLMMessage(role: .system, text: AskMishContext.systemPrompt(
            date: Date(), accountEmails: store?.accounts.map(\.id) ?? []))
    }

    // MARK: - Thread attachments

    /// Pins a thread to the conversation. Its markdown goes into the history
    /// on the next user turn (once — `injectedThreadIDs` dedupes).
    func attachThread(id: String, subject: String) {
        guard !attachedThreads.contains(where: { $0.id == id }) else { return }
        attachedThreads.append(AttachedThread(id: id, subject: subject))
    }

    /// Unpins a thread. Context that already went into the history stays —
    /// a sent message cannot be unsent — but nothing new is added for it.
    func detachThread(id: String) {
        attachedThreads.removeAll { $0.id == id }
    }

    /// FTS-backed thread search for the attach popover.
    func searchThreadsToAttach(query: String) async -> [AttachedThread] {
        let rows = try? await AppDatabase.shared.dbPool.read { db in
            try ThreadTypeahead.fetch(db: db, query: query, limit: 8)
        }
        return (rows ?? []).map { AttachedThread(id: $0.id, subject: $0.subject) }
    }

    /// The open thread plus every pinned thread as markdown, each injected
    /// once per conversation. Ordering and dedup live in
    /// `AskMishContext.threadsToInject` (pure, tested).
    private func contextMessages() -> [LLMMessage] {
        guard let store else { return [] }
        let current = includeSelectedThread ? store.selectedThread : nil
        let ids = AskMishContext.threadsToInject(
            currentThreadID: current?.id,
            attachedThreadIDs: attachedThreads.map(\.id),
            alreadyInjected: injectedThreadIDs)
        var subjects: [String: String] = [:]
        if let current { subjects[current.id] = current.subject }
        for attached in attachedThreads { subjects[attached.id] = attached.subject }
        var messages: [LLMMessage] = []
        for id in ids {
            let headers = store.messages(inThread: id)
            let hydrated = store.messagesWithBodies(ids: headers.map(\.id))
            let bodies = hydrated.isEmpty ? headers : hydrated
            guard !bodies.isEmpty else { continue }
            injectedThreadIDs.insert(id)
            messages.append(AskMishContext.contextMessage(
                threadId: id,
                threadMarkdown: ThreadExporter.markdown(
                    subject: subjects[id] ?? "", messages: bodies)))
        }
        return messages
    }

    /// Appends one assistant turn to the wire history.
    ///
    /// The empty guard mirrors `persistTurn`: an assistant message with no text
    /// and no calls serializes to `{"role":"assistant","content":[]}`, which
    /// Anthropic rejects with a 400. A stop before the first token used to
    /// append exactly that and poison every later send in the conversation.
    /// The guard lives here so no caller can bypass it.
    private func appendToHistory(assistantText: String, calls: [LLMToolCall],
                                results: [LLMToolResult]? = nil) {
        guard !assistantText.isEmpty || !calls.isEmpty else { return }
        history.append(LLMMessage(role: .assistant, text: assistantText, toolCalls: calls))
        if let results, !results.isEmpty {
            history.append(LLMMessage(role: .tool, text: "", toolResults: results))
        }
    }

    // MARK: - Bubble edits

    private func beginAssistantBubble() -> UUID {
        let bubble = Bubble(id: UUID(), role: .assistant, text: "", isStreaming: true)
        bubbles.append(bubble)
        return bubble.id
    }

    private func updateBubble(_ id: UUID, text: String) {
        guard let index = bubbles.firstIndex(where: { $0.id == id }) else { return }
        bubbles[index].text = text
    }

    private func appendReasoning(_ id: UUID, _ trace: String) {
        guard let index = bubbles.firstIndex(where: { $0.id == id }) else { return }
        bubbles[index].reasoningText += trace
    }

    private func finishBubble(_ id: UUID, costLabel: String?) {
        guard let index = bubbles.firstIndex(where: { $0.id == id }) else { return }
        bubbles[index].isStreaming = false
        bubbles[index].costLabel = costLabel
    }

    private func markInterrupted(_ id: UUID) {
        guard let index = bubbles.firstIndex(where: { $0.id == id }) else { return }
        bubbles[index].isStreaming = false
        if bubbles[index].text.isEmpty {
            bubbles[index].text = "Stopped."
        } else {
            bubbles[index].text += "\n\n_Stopped._"
        }
    }

    /// Failures replace the streaming bubble instead of adding one, so a dead
    /// stream does not leave an empty bubble above the error.
    private func markError(_ id: UUID, _ message: String) {
        guard let index = bubbles.firstIndex(where: { $0.id == id }) else {
            appendError(message)
            return
        }
        bubbles[index].isStreaming = false
        bubbles[index].isError = true
        if !bubbles[index].text.isEmpty { bubbles[index].text += "\n\n" }
        bubbles[index].text += message
    }

    /// Errors are shown but never stored: they are not part of the model's
    /// history and would only confuse the next turn.
    private func appendError(_ message: String) {
        bubbles.append(Bubble(id: UUID(), role: .assistant, text: message, isError: true))
    }

    // MARK: - Cost

    private func addUsage(_ usage: LLMUsage?) {
        guard let usage else { return }
        totalPromptTokens += usage.promptTokens
        totalCompletionTokens += usage.completionTokens
    }

    private func totalCostLabel() -> String? {
        guard totalPromptTokens > 0 || totalCompletionTokens > 0,
              let config = currentProviderConfig() else { return nil }
        return LLMPricing.costLabel(
            usage: LLMUsage(promptTokens: totalPromptTokens,
                            completionTokens: totalCompletionTokens),
            config: config, model: modelID, overrides: LLMPricing.loadOverrides())
    }

    // MARK: - Persistence

    /// Creates the conversation row on the first turn, and keeps the model
    /// choice and `updatedAt` current after that.
    private func ensureConversation(firstUserText: String) async {
        let now = Date()
        if let id = conversationID {
            let provider = providerID.uuidString
            let model = modelID
            try? await AppDatabase.shared.dbPool.write { db in
                guard var row = try ChatConversationRow.fetchOne(db, key: id) else { return }
                row.providerID = provider
                row.modelID = model
                row.updatedAt = now
                try row.update(db)
            }
            return
        }
        let row = ChatConversationRow(
            id: UUID().uuidString,
            title: AskMishContext.title(fromFirstUserText: firstUserText),
            providerID: providerID.uuidString, modelID: modelID,
            createdAt: now, updatedAt: now)
        do {
            try await AppDatabase.shared.dbPool.write { db in try row.insert(db) }
            conversationID = row.id
        } catch {
            // A failed insert only costs persistence; the turn still runs.
            conversationID = nil
        }
    }

    /// Adds the user turn (plus the thread context, when it is due) to the
    /// history, the transcript, and the database.
    private func appendUser(_ text: String) async {
        history.append(contentsOf: contextMessages())
        let bubble = Bubble(id: UUID(), role: .user, text: text)
        bubbles.append(bubble)
        history.append(LLMMessage(role: .user, text: text))
        await write(rows: [ChatMessageRow(
            id: bubble.id.uuidString, conversationId: conversationID ?? "",
            role: LLMRole.user.rawValue, text: text,
            toolCallsJSON: "[]", toolResultsJSON: "[]",
            promptTokens: nil, completionTokens: nil, createdAt: Date())])
    }

    /// Writes one assistant turn. The assistant row and its tool row go in the
    /// same transaction so a reload never sees a tool_use without its results.
    private func persistTurn(assistantText: String, calls: [LLMToolCall],
                             results: [LLMToolResult]?, usage: LLMUsage?) async {
        guard !assistantText.isEmpty || !calls.isEmpty else { return }
        let now = Date()
        var rows = [ChatMessageRow(
            id: UUID().uuidString, conversationId: conversationID ?? "",
            role: LLMRole.assistant.rawValue, text: assistantText,
            toolCallsJSON: Self.encode(calls), toolResultsJSON: "[]",
            promptTokens: usage?.promptTokens, completionTokens: usage?.completionTokens,
            createdAt: now)]
        if let results, !results.isEmpty {
            rows.append(ChatMessageRow(
                id: UUID().uuidString, conversationId: conversationID ?? "",
                role: LLMRole.tool.rawValue, text: "",
                toolCallsJSON: "[]", toolResultsJSON: Self.encode(results),
                promptTokens: nil, completionTokens: nil,
                // One millisecond later, so the ordered reload keeps the pair
                // in order even if both rows land on the same instant.
                createdAt: now.addingTimeInterval(0.001)))
        }
        await write(rows: rows)
    }

    private func write(rows: [ChatMessageRow]) async {
        guard let id = conversationID, !id.isEmpty else { return }
        let updatedAt = rows.last?.createdAt ?? Date()
        try? await AppDatabase.shared.dbPool.write { db in
            for row in rows { try row.insert(db) }
            if var conversation = try ChatConversationRow.fetchOne(db, key: id) {
                conversation.updatedAt = updatedAt
                try conversation.update(db)
            }
        }
    }

    private static func encode<T: Encodable>(_ value: [T]) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }
}
