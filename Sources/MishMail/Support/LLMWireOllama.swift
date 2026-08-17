import Foundation

/// Pure codec for Ollama's /api/chat NDJSON streaming format.
enum OllamaChatWire {
    static func requestBody(model: String, messages: [LLMMessage],
                            tools: [LLMToolSpec]) throws -> Data {
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
