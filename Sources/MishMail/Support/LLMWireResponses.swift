import Foundation

/// OpenAI Responses API codec. GPT-6.1 Sol can call tools only here.
/// GPT-6 Sol and Luna use it for tool calls unless reasoning is off.
enum OpenAIResponses {
    static func leaf(_ model: String) -> String {
        (model.split(separator: "/").last.map(String.init) ?? model).lowercased()
    }

    static func isGPT61Sol(_ model: String) -> Bool {
        let name = leaf(model)
        return name == "gpt-6.1-sol" || name.hasPrefix("gpt-6.1-sol-")
    }

    static func isGPT6SolOrLuna(_ model: String) -> Bool {
        let name = leaf(model)
        return name == "gpt-6-sol" || name.hasPrefix("gpt-6-sol-")
            || name == "gpt-6-luna" || name.hasPrefix("gpt-6-luna-")
    }

    /// Codex ChatGPT sign-in. Its token cannot call `api.openai.com`.
    static let codexResponsesURL = "https://chatgpt.com/backend-api/codex/responses"

    static func isChatGPTSubscription(_ config: LLMProviderConfig) -> Bool {
        if case .oauth(.chatGPT) = config.authMode { return true }
        return false
    }

    /// True when this request must go to the Responses API.
    /// A ChatGPT subscription uses the Codex backend, not `api.openai.com`.
    static func usesResponses(host: String?, model: String,
                              hasTools: Bool, thinking: LLMThinking,
                              chatGPTSubscription: Bool = false) -> Bool {
        if chatGPTSubscription { return true }
        guard hasTools, host == "api.openai.com" else { return false }
        if isGPT61Sol(model) { return true }
        return isGPT6SolOrLuna(model) && thinking != .off
    }

    /// Drops reasoning items from the current turn. A provider change cannot
    /// decrypt items made by the previous account.
    static func withoutCurrentTurnReasoning(_ messages: [LLMMessage]) -> [LLMMessage] {
        let loopStart = messages.lastIndex { $0.role == .user } ?? -1
        return messages.enumerated().map { index, message in
            guard index > loopStart else { return message }
            var copy = message
            copy.thinkingBlocks.removeAll { $0.responsesItemJSON != nil }
            return copy
        }
    }

    static func endpoint(baseURL: String, chatGPTSubscription: Bool) -> String {
        chatGPTSubscription
            ? codexResponsesURL
            : LLMEndpoint.responsesPath(base: baseURL)
    }

    /// `chatgpt_account_id` from a ChatGPT access token. The value is not logged.
    static func chatGPTAccountID(in accessToken: String) -> String? {
        let parts = accessToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder != 0 { payload += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let auth = object["https://api.openai.com/auth"] as? [String: Any],
           let id = auth["chatgpt_account_id"] as? String, !id.isEmpty {
            return id
        }
        if let id = object["chatgpt_account_id"] as? String, !id.isEmpty { return id }
        return nil
    }

    /// Effort sent as `reasoning.effort`. GPT-6.1 Sol rejects `none`, so Off
    /// becomes `low`, the smallest effort that model accepts.
    static func reasoningEffort(model: String, thinking: LLMThinking) -> String? {
        switch thinking {
        case .modelDefault:
            return nil
        case .off:
            return isGPT61Sol(model) ? "low" : "none"
        case .level(let level):
            return LLMHostedThinking.openAIEffort(level, model: model)
        }
    }

    static func requestBody(model: String, messages: [LLMMessage],
                            tools: [LLMToolSpec],
                            thinking: LLMThinking = .modelDefault,
                            toolChoiceNone: Bool = false,
                            codexBackend: Bool = false) throws -> Data {
        var instructions: [String] = []
        var input: [[String: Any]] = []
        // Reasoning items are bound to the provider that made them. Replay
        // them only inside the current turn, after the last user message.
        let loopStart = messages.lastIndex { $0.role == .user } ?? -1
        for (index, message) in messages.enumerated() {
            switch message.role {
            case .system:
                if !message.text.isEmpty { instructions.append(message.text) }
            case .user:
                input.append(["role": "user", "content": message.text])
            case .assistant:
                if index > loopStart {
                    for block in message.thinkingBlocks {
                        guard let json = block.responsesItemJSON,
                              let data = json.data(using: .utf8),
                              let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        input.append(item)
                    }
                }
                if !message.text.isEmpty {
                    input.append(["role": "assistant", "content": message.text])
                }
                for call in message.toolCalls {
                    input.append([
                        "type": "function_call",
                        "call_id": call.id,
                        "name": call.name,
                        "arguments": call.argumentsJSON,
                    ])
                }
            case .tool:
                for result in message.toolResults {
                    input.append([
                        "type": "function_call_output",
                        "call_id": result.callID,
                        "output": result.content,
                    ])
                }
            }
        }
        var body: [String: Any] = [
            "model": model,
            "input": input,
            "stream": true,
        ]
        if codexBackend || !instructions.isEmpty {
            body["instructions"] = instructions.joined(separator: "\n\n")
        }
        if !tools.isEmpty {
            body["tools"] = try tools.map { tool -> [String: Any] in
                let schema = try JSONSerialization.jsonObject(
                    with: Data(tool.inputSchemaJSON.utf8))
                return ["type": "function",
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": schema,
                        "strict": false]
            }
            if toolChoiceNone { body["tool_choice"] = "none" }
        }
        if let effort = reasoningEffort(model: model, thinking: thinking) {
            body["reasoning"] = ["effort": effort]
        }
        // Ask Mish replays the conversation itself, so the reasoning item must
        // travel with the next tool result. Encrypted content is that item.
        body["include"] = ["reasoning.encrypted_content"]
        // Mail history is managed locally, including encrypted reasoning for tool turns.
        body["store"] = false
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Incremental SSE parser for Responses events.
    struct StreamState {
        private struct PartialCall { var id = ""; var name = ""; var args = "" }
        private var partial: [Int: PartialCall] = [:]
        private var usage: LLMUsage?
        private var finished = false
        private var seenReasoning: Set<String> = []

        mutating func consume(line: String) -> [LLMEvent] {
            guard !finished, line.hasPrefix("data:") else { return [] }
            var payload = String(line.dropFirst(5))
            if payload.hasSuffix("\r") { payload.removeLast() }
            payload = payload.trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { return abandon() }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [] }
            if let providerError = object["error"] as? [String: Any] {
                return [.error(providerError["message"] as? String ?? "Responses stream failed")]
            }
            if let providerError = object["error"] as? String {
                return [.error(providerError)]
            }
            switch object["type"] as? String ?? "" {
            case "response.output_text.delta":
                if let text = object["delta"] as? String, !text.isEmpty {
                    return [.token(text)]
                }
            case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
                if let text = object["delta"] as? String, !text.isEmpty {
                    return [.reasoning(text)]
                }
            case "response.output_item.added":
                captureItem(object)
            case "response.output_item.done":
                return doneItemEvents(object)
            case "response.function_call_arguments.delta":
                appendArgs(object)
            case "response.function_call_arguments.done":
                replaceArgs(object)
            case "response.completed":
                captureUsage(object["response"])
                if let response = object["response"] as? [String: Any],
                   let output = response["output"] as? [[String: Any]] {
                    for (index, item) in output.enumerated() where item["type"] as? String == "function_call" {
                        captureItem(["output_index": index, "item": item])
                    }
                }
                return reasoningEvents(in: object["response"]) + finish()
            case "response.incomplete":
                finished = true
                captureUsage(object["response"])
                return [.done(stopReason: "length", usage: usage)]
            case "response.failed":
                return [.error(failureMessage(object))]
            case "error":
                return [.error(object["message"] as? String ?? "Responses stream failed")]
            default:
                break
            }
            return []
        }

        /// The socket closed before `response.completed`. Drop any partial
        /// tool call. Releasing it would run or confirm an unfinished call.
        mutating func abandon() -> [LLMEvent] {
            if finished { return [] }
            finished = true
            partial = [:]
            return [.error("The response ended before it completed.")]
        }

        /// Release tool calls only after the entire response completes.
        private mutating func finish() -> [LLMEvent] {
            if finished { return [] }
            finished = true
            var events: [LLMEvent] = []
            for (_, call) in partial.sorted(by: { $0.key < $1.key }) {
                guard !call.id.isEmpty, !call.name.isEmpty,
                      (try? JSONSerialization.jsonObject(with: Data(call.args.utf8))) is [String: Any]
                else { return [.error("The provider returned an incomplete tool call.")] }
                events.append(.toolCall(LLMToolCall(
                    id: call.id, name: call.name, argumentsJSON: call.args)))
            }
            events.append(.done(stopReason: partial.isEmpty ? "stop" : "tool_calls", usage: usage))
            return events
        }

        /// `encrypted_content` arrives on `output_item.done`, not on the
        /// earlier deltas. Replay that object on the next tool turn.
        private mutating func doneItemEvents(_ object: [String: Any]) -> [LLMEvent] {
            guard let item = object["item"] as? [String: Any] else { return [] }
            switch item["type"] as? String {
            case "function_call":
                captureItem(object)
                return []
            case "reasoning":
                return reasoningEvents(from: [item])
            default:
                return []
            }
        }

        private mutating func reasoningEvents(in response: Any?) -> [LLMEvent] {
            guard let response = response as? [String: Any],
                  let output = response["output"] as? [[String: Any]] else { return [] }
            return reasoningEvents(from: output)
        }

        private mutating func reasoningEvents(from items: [[String: Any]]) -> [LLMEvent] {
            var events: [LLMEvent] = []
            for item in items where item["type"] as? String == "reasoning" {
                let id = item["id"] as? String ?? ""
                if !id.isEmpty, !seenReasoning.insert(id).inserted { continue }
                guard let data = try? JSONSerialization.data(withJSONObject: item),
                      let json = String(data: data, encoding: .utf8) else { continue }
                events.append(.thinkingBlock(LLMThinkingBlock(responsesItemJSON: json)))
            }
            return events
        }

        private mutating func captureItem(_ object: [String: Any]) {
            guard let item = object["item"] as? [String: Any],
                  item["type"] as? String == "function_call" else { return }
            guard let index = object["output_index"] as? Int else { return }
            var call = partial[index] ?? PartialCall()
            if let id = item["call_id"] as? String, !id.isEmpty {
                call.id = id
            }
            if let name = item["name"] as? String { call.name = name }
            if let args = item["arguments"] as? String, !args.isEmpty { call.args = args }
            partial[index] = call
        }

        private mutating func appendArgs(_ object: [String: Any]) {
            guard let index = object["output_index"] as? Int else { return }
            var call = partial[index] ?? PartialCall()
            if let delta = object["delta"] as? String { call.args += delta }
            partial[index] = call
        }

        private mutating func replaceArgs(_ object: [String: Any]) {
            guard let index = object["output_index"] as? Int else { return }
            var call = partial[index] ?? PartialCall()
            if let args = object["arguments"] as? String, !args.isEmpty { call.args = args }
            partial[index] = call
        }

        private mutating func captureUsage(_ response: Any?) {
            guard let response = response as? [String: Any],
                  let usageObject = response["usage"] as? [String: Any] else { return }
            var usage = LLMUsage(
                promptTokens: usageObject["input_tokens"] as? Int ?? 0,
                completionTokens: usageObject["output_tokens"] as? Int ?? 0)
            if let details = usageObject["input_tokens_details"] as? [String: Any],
               let cached = details["cached_tokens"] as? Int {
                usage.cacheReadInputTokens = cached
            }
            self.usage = usage
        }

        private func failureMessage(_ object: [String: Any]) -> String {
            if let response = object["response"] as? [String: Any],
               let error = response["error"] as? [String: Any],
               let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            return object["message"] as? String ?? "Responses stream failed"
        }
    }
}
