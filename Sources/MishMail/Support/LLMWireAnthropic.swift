import Foundation

/// Pure codec for the Anthropic Messages API (SSE streaming, tool use).
enum AnthropicWire {
    static func requestBody(model: String, messages: [LLMMessage],
                            tools: [LLMToolSpec], maxTokens: Int,
                            thinking: LLMThinking = .modelDefault,
                            toolChoiceNone: Bool = false) throws -> Data {
        var system = ""
        var wireMessages: [[String: Any]] = []
        for message in messages {
            switch message.role {
            case .system:
                system = message.text
            case .user:
                wireMessages.append(["role": "user",
                                     "content": [["type": "text", "text": message.text]]])
            case .assistant:
                var content: [[String: Any]] = []
                for block in message.thinkingBlocks {
                    if let data = block.redactedData, !data.isEmpty {
                        content.append(["type": "redacted_thinking", "data": data])
                    } else if !block.signature.isEmpty {
                        content.append(["type": "thinking",
                                        "thinking": block.thinking,
                                        "signature": block.signature])
                    }
                }
                if !message.text.isEmpty {
                    content.append(["type": "text", "text": message.text])
                }
                for call in message.toolCalls {
                    let input = (try? JSONSerialization.jsonObject(
                        with: Data(call.argumentsJSON.utf8))) ?? [:]
                    content.append(["type": "tool_use", "id": call.id,
                                    "name": call.name, "input": input])
                }
                wireMessages.append(["role": "assistant", "content": content])
            case .tool:
                let content: [[String: Any]] = message.toolResults.map { result in
                    ["type": "tool_result", "tool_use_id": result.callID,
                     "content": result.content, "is_error": result.isError]
                }
                wireMessages.append(["role": "user", "content": content])
            }
        }
        var resolvedMax = min(maxTokens, LLMHostedThinking.anthropicOutputCap(model))
        if LLMHostedThinking.supports(model), !isDefaultThinking(thinking) {
            resolvedMax = LLMHostedThinking.anthropicMaxTokens(
                model: model, thinking: thinking, defaultValue: maxTokens)
        }
        var body: [String: Any] = [
            "model": model,
            "messages": wireMessages,
            "stream": true,
        ]
        applyThinking(model: model, thinking: thinking, maxTokens: &resolvedMax, to: &body)
        resolvedMax = min(resolvedMax, LLMHostedThinking.anthropicOutputCap(model))
        body["max_tokens"] = resolvedMax
        if !system.isEmpty {
            body["system"] = [["type": "text", "text": system,
                                "cache_control": ["type": "ephemeral"]]]
        }
        if let last = wireMessages.indices.last,
           var content = wireMessages[last]["content"] as? [[String: Any]],
           let block = content.indices.last {
            content[block]["cache_control"] = ["type": "ephemeral"]
            wireMessages[last]["content"] = content
            body["messages"] = wireMessages
        }
        if !tools.isEmpty {
            body["tools"] = try tools.map { tool -> [String: Any] in
                ["name": tool.name, "description": tool.description,
                 "input_schema": try JSONSerialization.jsonObject(
                    with: Data(tool.inputSchemaJSON.utf8))]
            }
            // History with tool_use/tool_result blocks needs `tools` defined,
            // so an answer-only request keeps them and forbids calls instead.
            if toolChoiceNone { body["tool_choice"] = ["type": "none"] }
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Encodes thinking only when this model accepts it. A level on a
    /// non-thinking id is omitted so the request still runs.
    private static func applyThinking(model: String, thinking: LLMThinking,
                                      maxTokens: inout Int,
                                      to body: inout [String: Any]) {
        guard LLMHostedThinking.supports(model) else { return }
        switch thinking {
        case .modelDefault:
            return
        case .off:
            // Claude 4.6+ accepts disabled. Fable and older thinking models
            // 400 on it, so omit and keep the model's own default.
            if LLMHostedThinking.acceptsDisabled(model) {
                body["thinking"] = ["type": "disabled"]
            }
        case .level(let level):
            if LLMHostedThinking.usesAdaptive(model) {
                body["thinking"] = ["type": "adaptive"]
                body["output_config"] = [
                    "effort": LLMHostedThinking.anthropicEffort(level, model: model)
                ]
            } else {
                let plan = budgetPlan(level: level, maxTokens: maxTokens,
                                      cap: LLMHostedThinking.anthropicOutputCap(model))
                maxTokens = plan.maxTokens
                body["thinking"] = ["type": "enabled", "budget_tokens": plan.budget]
            }
        }
    }

    /// Answer room kept beside a thinking budget. A budget of `cap - 1`
    /// left one token for the answer, so every reply came back cut off.
    static let answerReserveTokens = 8_192
    static let minimumThinkingBudget = 1_024

    /// Budget-thinking models: keep `answerReserveTokens` of the output cap
    /// for the answer, never go under the API's 1024 floor, and size
    /// `max_tokens` to budget plus that reserve within the cap.
    static func budgetPlan(level: String, maxTokens: Int,
                           cap: Int) -> (budget: Int, maxTokens: Int) {
        let budget = max(minimumThinkingBudget,
                         min(LLMHostedThinking.budgetTokens(level),
                             cap - answerReserveTokens))
        let resolved = min(cap, max(maxTokens, budget + answerReserveTokens))
        return (budget, resolved)
    }

    private static func isDefaultThinking(_ thinking: LLMThinking) -> Bool {
        if case .modelDefault = thinking { return true }
        return false
    }

    struct StreamState {
        private var toolID = ""
        private var toolName = ""
        private var toolArgs = ""
        private var inToolBlock = false
        private var inThinking = false
        private var thinkingText = ""
        private var thinkingSignature = ""
        private var redactedData: String?
        private var promptTokens = 0
        private var completionTokens = 0
        private var stopReason = "end_turn"

        mutating func consume(line: String) -> [LLMEvent] {
            // Accept "data:" with or without a space, and tolerate a trailing
            // CR from CRLF transports.
            guard line.hasPrefix("data:") else { return [] }
            var payload = String(line.dropFirst(5))
            if payload.hasSuffix("\r") { payload.removeLast() }
            payload = payload.trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String
            else { return [] }
            switch type {
            case "message_start":
                if let usage = (object["message"] as? [String: Any])?["usage"] as? [String: Any],
                   let input = usage["input_tokens"] as? Int {
                    promptTokens = input
                }
                if let usage = (object["message"] as? [String: Any])?["usage"] as? [String: Any] {
                    cacheCreationInputTokens = usage["cache_creation_input_tokens"] as? Int ?? 0
                    cacheReadInputTokens = usage["cache_read_input_tokens"] as? Int ?? 0
                }
                return []
            case "content_block_start":
                if let block = object["content_block"] as? [String: Any] {
                    switch block["type"] as? String {
                    case "tool_use":
                        inToolBlock = true
                        toolID = block["id"] as? String ?? ""
                        toolName = block["name"] as? String ?? ""
                        toolArgs = ""
                    case "thinking":
                        inThinking = true
                        thinkingText = block["thinking"] as? String ?? ""
                        thinkingSignature = block["signature"] as? String ?? ""
                        redactedData = nil
                    case "redacted_thinking":
                        inThinking = true
                        thinkingText = ""
                        thinkingSignature = ""
                        redactedData = block["data"] as? String ?? ""
                    default:
                        break
                    }
                }
                return []
            case "content_block_delta":
                guard let delta = object["delta"] as? [String: Any] else { return [] }
                if let text = delta["text"] as? String, !text.isEmpty {
                    return [.token(text)]
                }
                if let trace = delta["thinking"] as? String, !trace.isEmpty {
                    thinkingText += trace
                    return [.reasoning(trace)]
                }
                if let signature = delta["signature"] as? String, !signature.isEmpty {
                    thinkingSignature += signature
                    return []
                }
                if let partial = delta["partial_json"] as? String {
                    toolArgs += partial
                }
                return []
            case "content_block_stop":
                if inThinking {
                    inThinking = false
                    let block = LLMThinkingBlock(thinking: thinkingText,
                                                 signature: thinkingSignature,
                                                 redactedData: redactedData)
                    thinkingText = ""
                    thinkingSignature = ""
                    redactedData = nil
                    return [.thinkingBlock(block)]
                }
                guard inToolBlock else { return [] }
                inToolBlock = false
                let call = LLMToolCall(id: toolID, name: toolName,
                                       argumentsJSON: toolArgs.isEmpty ? "{}" : toolArgs)
                return [.toolCall(call)]
            case "message_delta":
                if let delta = object["delta"] as? [String: Any],
                   let reason = delta["stop_reason"] as? String {
                    stopReason = reason
                }
                if let usage = object["usage"] as? [String: Any],
                   let output = usage["output_tokens"] as? Int {
                    completionTokens = output
                }
                if let usage = object["usage"] as? [String: Any] {
                    cacheCreationInputTokens = usage["cache_creation_input_tokens"] as? Int
                        ?? cacheCreationInputTokens
                    cacheReadInputTokens = usage["cache_read_input_tokens"] as? Int
                        ?? cacheReadInputTokens
                }
                return []
            case "message_stop":
                sawMessageStop = true
                return [.done(stopReason: stopReason,
                              usage: LLMUsage(promptTokens: promptTokens,
                                              completionTokens: completionTokens,
                                              cacheCreationInputTokens: cacheCreationInputTokens,
                                              cacheReadInputTokens: cacheReadInputTokens))]
            case "error":
                let providerError = object["error"] as? [String: Any]
                let message = providerError?["message"] as? String
                    ?? object["error"] as? String
                    ?? object["message"] as? String
                    ?? "Anthropic stream failed"
                return [.error(message)]
            default:
                return []
            }
        }

        private var cacheCreationInputTokens = 0
        private var cacheReadInputTokens = 0
        private(set) var sawMessageStop = false

        mutating func finalEvents() -> [LLMEvent] {
            sawMessageStop ? [] : [.error("stream ended early")]
        }
    }
}
