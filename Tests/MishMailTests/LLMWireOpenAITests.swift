import XCTest

final class LLMWireOpenAITests: XCTestCase {
    private func decode(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testRequestBodyMapsRolesToolCallsAndResults() throws {
        let messages: [LLMMessage] = [
            LLMMessage(role: .system, text: "be brief"),
            LLMMessage(role: .user, text: "hi"),
            LLMMessage(role: .assistant, text: "",
                       toolCalls: [LLMToolCall(id: "c1", name: "search_threads",
                                               argumentsJSON: #"{"query":"acme"}"#)]),
            LLMMessage(role: .tool, text: "",
                       toolResults: [LLMToolResult(callID: "c1", content: "[]", isError: false)]),
        ]
        let tools = [LLMToolSpec(name: "search_threads", description: "Search mail",
                                 inputSchemaJSON: #"{"type":"object"}"#)]
        let body = try decode(try OpenAIWire.requestBody(
            model: "grok-4-0709", messages: messages, tools: tools))

        XCTAssertEqual(body["model"] as? String, "grok-4-0709")
        XCTAssertEqual(body["stream"] as? Bool, true)
        let wireMessages = body["messages"] as! [[String: Any]]
        XCTAssertEqual(wireMessages.map { $0["role"] as! String },
                       ["system", "user", "assistant", "tool"])
        let call = ((wireMessages[2]["tool_calls"] as! [[String: Any]])[0])
        XCTAssertEqual(call["id"] as? String, "c1")
        XCTAssertEqual((call["function"] as! [String: Any])["name"] as? String, "search_threads")
        XCTAssertEqual(wireMessages[3]["tool_call_id"] as? String, "c1")
        let toolDef = (body["tools"] as! [[String: Any]])[0]["function"] as! [String: Any]
        XCTAssertEqual(toolDef["name"] as? String, "search_threads")
    }

    func testStreamTokensThenDoneWithUsage() {
        var state = OpenAIWire.StreamState()
        var events: [LLMEvent] = []
        events += state.consume(line: #"data: {"choices":[{"delta":{"content":"Hel"}}]}"#)
        events += state.consume(line: #"data: {"choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}]}"#)
        events += state.consume(line: #"data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":3}}"#)
        events += state.consume(line: "data: [DONE]")
        XCTAssertEqual(events, [
            .token("Hel"), .token("lo"),
            .done(stopReason: "stop", usage: LLMUsage(promptTokens: 12, completionTokens: 3)),
        ])
    }

    func testStreamAccumulatesChunkedToolCall() {
        var state = OpenAIWire.StreamState()
        var events: [LLMEvent] = []
        events += state.consume(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c9","function":{"name":"get_thread","arguments":""}}]}}]}"#)
        events += state.consume(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"id\":"}}]}}]}"#)
        events += state.consume(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"t1\"}"}}]},"finish_reason":"tool_calls"}]}"#)
        events += state.consume(line: "data: [DONE]")
        XCTAssertEqual(events, [
            .toolCall(LLMToolCall(id: "c9", name: "get_thread", argumentsJSON: #"{"id":"t1"}"#)),
            .done(stopReason: "tool_calls", usage: nil),
        ])
    }

    func testNonDataLinesAreIgnored() {
        var state = OpenAIWire.StreamState()
        XCTAssertEqual(state.consume(line: ""), [])
        XCTAssertEqual(state.consume(line: ": keep-alive"), [])
    }
}
