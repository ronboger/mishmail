import Foundation

/// Pure codec for the Anthropic Messages API (SSE streaming, tool use).
enum AnthropicWire {
    static func requestBody(model: String, messages: [LLMMessage],
                            tools: [LLMToolSpec], maxTokens: Int,
                            thinking: LLMThinking = .modelDefault) throws -> Data {
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
                    } else {
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
        var resolvedMax = maxTokens
        var body: [String: Any] = [
            "model": model,
            "messages": wireMessages,
            "stream": true,
        ]
        applyThinking(model: model, thinking: thinking, maxTokens: &resolvedMax, to: &body)
        body["max_tokens"] = resolvedMax
        if !system.isEmpty { body["system"] = system }
        if !tools.isEmpty {
            body["tools"] = try tools.map { tool -> [String: Any] in
                ["name": tool.name, "description": tool.description,
                 "input_schema": try JSONSerialization.jsonObject(
                    with: Data(tool.inputSchemaJSON.utf8))]
            }
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
                let budget = LLMHostedThinking.budgetTokens(level)
                if maxTokens <= budget { maxTokens = budget + 8_192 }
                body["thinking"] = ["type": "enabled", "budget_tokens": budget]
            }
        }
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
                return []
            case "message_stop":
                return [.done(stopReason: stopReason,
                              usage: LLMUsage(promptTokens: promptTokens,
                                              completionTokens: completionTokens))]
            default:
                return []
            }
        }
    }
}
