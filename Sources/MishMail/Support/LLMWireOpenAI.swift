import Foundation

/// Pure codec for the OpenAI Chat Completions wire format (SSE streaming).
/// Also speaks for OpenRouter, Groq, xAI Grok, and LM Studio.
enum OpenAIWire {
    static func requestBody(model: String, messages: [LLMMessage],
                            tools: [LLMToolSpec]) throws -> Data {
        var wireMessages: [[String: Any]] = []
        for message in messages {
            switch message.role {
            case .system:
                wireMessages.append(["role": "system", "content": message.text])
            case .user:
                wireMessages.append(["role": "user", "content": message.text])
            case .assistant:
                var m: [String: Any] = ["role": "assistant", "content": message.text]
                if !message.toolCalls.isEmpty {
                    m["tool_calls"] = message.toolCalls.map { call in
                        ["id": call.id, "type": "function",
                         "function": ["name": call.name, "arguments": call.argumentsJSON]]
                    }
                }
                wireMessages.append(m)
            case .tool:
                for result in message.toolResults {
                    wireMessages.append(["role": "tool",
                                         "tool_call_id": result.callID,
                                         "content": result.content])
                }
            }
        }
        var body: [String: Any] = [
            "model": model,
            "messages": wireMessages,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if !tools.isEmpty {
            body["tools"] = try tools.map { tool -> [String: Any] in
                let schema = try JSONSerialization.jsonObject(
                    with: Data(tool.inputSchemaJSON.utf8))
                return ["type": "function",
                        "function": ["name": tool.name,
                                     "description": tool.description,
                                     "parameters": schema]]
            }
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Incremental SSE parser. Feed each line; collect events. Tool-call
    /// argument fragments accumulate by index until finish_reason arrives.
    struct StreamState {
        private struct PartialCall { var id = ""; var name = ""; var args = "" }
        private var partial: [Int: PartialCall] = [:]
        private var stopReason = "stop"
        private var usage: LLMUsage?
        private var pendingToolEvents: [LLMEvent] = []

        mutating func consume(line: String) -> [LLMEvent] {
            guard line.hasPrefix("data: ") else { return [] }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" {
                let events = pendingToolEvents + [LLMEvent.done(stopReason: stopReason, usage: usage)]
                pendingToolEvents = []
                return events
            }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [] }
            if let u = object["usage"] as? [String: Any],
               let prompt = u["prompt_tokens"] as? Int,
               let completion = u["completion_tokens"] as? Int {
                usage = LLMUsage(promptTokens: prompt, completionTokens: completion)
            }
            guard let choice = (object["choices"] as? [[String: Any]])?.first else { return [] }
            var events: [LLMEvent] = []
            if let delta = choice["delta"] as? [String: Any] {
                if let text = delta["content"] as? String, !text.isEmpty {
                    events.append(.token(text))
                }
                for fragment in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let index = fragment["index"] as? Int ?? 0
                    var call = partial[index] ?? PartialCall()
                    if let id = fragment["id"] as? String { call.id = id }
                    if let function = fragment["function"] as? [String: Any] {
                        if let name = function["name"] as? String { call.name = name }
                        if let args = function["arguments"] as? String { call.args += args }
                    }
                    partial[index] = call
                }
            }
            if let reason = choice["finish_reason"] as? String {
                stopReason = reason
                if reason == "tool_calls" {
                    for index in partial.keys.sorted() {
                        let call = partial[index]!
                        pendingToolEvents.append(.toolCall(LLMToolCall(
                            id: call.id, name: call.name, argumentsJSON: call.args)))
                    }
                    partial = [:]
                }
            }
            return events
        }
    }
}
