import Foundation

/// Pure codec for Ollama's /api/chat NDJSON streaming format.
enum OllamaChatWire {
    /// `keepAliveSeconds` is Ollama's `keep_alive`: how long the model stays in
    /// memory after the reply. 0 unloads at once, a negative value keeps it
    /// forever. `contextTokens` is `options.num_ctx`, which sizes the KV cache;
    /// pass nil or 0 to accept the server's own value.
    static func requestBody(model: String, messages: [LLMMessage],
                            tools: [LLMToolSpec],
                            keepAliveSeconds: Int? = nil,
                            contextTokens: Int? = nil) throws -> Data {
        var wireMessages: [[String: Any]] = []
        for message in messages {
            switch message.role {
            case .system, .user:
                wireMessages.append(["role": message.role.rawValue,
                                     "content": message.text])
            case .assistant:
                var wireMessage: [String: Any] = ["role": "assistant",
                                                  "content": message.text]
                if !message.toolCalls.isEmpty {
                    // Ollama wants arguments as a JSON object, not a string.
                    wireMessage["tool_calls"] = message.toolCalls.map { call -> [String: Any] in
                        let arguments = (try? JSONSerialization.jsonObject(
                            with: Data(call.argumentsJSON.utf8))) ?? [String: Any]()
                        return ["function": ["name": call.name, "arguments": arguments]]
                    }
                }
                wireMessages.append(wireMessage)
            case .tool:
                for result in message.toolResults {
                    wireMessages.append(["role": "tool", "content": result.content])
                }
            }
        }
        var body: [String: Any] = ["model": model, "messages": wireMessages, "stream": true]
        // Ollama defaults hold the weights in memory for five minutes and size
        // the KV cache from the model's own context length, which on a large
        // local model costs many gigabytes. Send both limits explicitly.
        if let keepAliveSeconds { body["keep_alive"] = keepAliveSeconds }
        if let contextTokens, contextTokens > 0 {
            body["options"] = ["num_ctx": contextTokens]
        }
        if !tools.isEmpty {
            body["tools"] = try tools.map { tool -> [String: Any] in
                ["type": "function",
                 "function": ["name": tool.name,
                              "description": tool.description,
                              "parameters": try JSONSerialization.jsonObject(
                                with: Data(tool.inputSchemaJSON.utf8))]]
            }
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Body that drops a model from memory now: an empty chat with keep_alive 0.
    /// Ollama answers immediately and frees the weights.
    static func unloadBody(model: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": model,
                                                    "messages": [],
                                                    "keep_alive": 0])
    }

    struct StreamState {
        private var callCount = 0

        mutating func consume(line: String) -> [LLMEvent] {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [] }
            var events: [LLMEvent] = []
            if let message = object["message"] as? [String: Any] {
                if let text = message["content"] as? String, !text.isEmpty {
                    events.append(.token(text))
                }
                if let trace = message["thinking"] as? String, !trace.isEmpty {
                    events.append(.reasoning(trace))
                }
                for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                    guard let function = call["function"] as? [String: Any],
                          let name = function["name"] as? String else { continue }
                    let arguments = function["arguments"] ?? [String: Any]()
                    let argsData = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data("{}".utf8)
                    events.append(.toolCall(LLMToolCall(
                        id: "call_\(callCount)", name: name,
                        argumentsJSON: String(decoding: argsData, as: UTF8.self))))
                    callCount += 1
                }
            }
            if object["done"] as? Bool == true {
                var usage: LLMUsage?
                if let prompt = object["prompt_eval_count"] as? Int,
                   let completion = object["eval_count"] as? Int {
                    usage = LLMUsage(promptTokens: prompt, completionTokens: completion)
                }
                events.append(.done(stopReason: object["done_reason"] as? String ?? "stop",
                                    usage: usage))
            }
            return events
        }
    }
}
