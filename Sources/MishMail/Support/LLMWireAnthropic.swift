import Foundation

/// Pure codec for the Anthropic Messages API (SSE streaming, tool use).
enum AnthropicWire {
    static func requestBody(model: String, messages: [LLMMessage],
                            tools: [LLMToolSpec], maxTokens: Int) throws -> Data {
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
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": wireMessages,
            "stream": true,
        ]
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

    struct StreamState {
        private var toolID = ""
        private var toolName = ""
        private var toolArgs = ""
        private var inToolBlock = false
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
                if let block = object["content_block"] as? [String: Any],
                   block["type"] as? String == "tool_use" {
                    inToolBlock = true
                    toolID = block["id"] as? String ?? ""
                    toolName = block["name"] as? String ?? ""
                    toolArgs = ""
                }
                return []
            case "content_block_delta":
                guard let delta = object["delta"] as? [String: Any] else { return [] }
                if let text = delta["text"] as? String, !text.isEmpty {
                    return [.token(text)]
                }
                if let trace = delta["thinking"] as? String, !trace.isEmpty {
                    return [.reasoning(trace)]
                }
                if let partial = delta["partial_json"] as? String {
                    toolArgs += partial
                }
                return []
            case "content_block_stop":
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
