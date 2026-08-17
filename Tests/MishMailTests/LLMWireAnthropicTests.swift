import XCTest

final class LLMWireAnthropicTests: XCTestCase {
    private func decode(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testRequestBodyHoistsSystemAndMapsToolBlocks() throws {
        let messages: [LLMMessage] = [
            LLMMessage(role: .system, text: "be brief"),
            LLMMessage(role: .user, text: "hi"),
            LLMMessage(role: .assistant, text: "checking",
                       toolCalls: [LLMToolCall(id: "tu1", name: "get_thread",
                                               argumentsJSON: #"{"id":"t1"}"#)]),
            LLMMessage(role: .tool, text: "",
                       toolResults: [LLMToolResult(callID: "tu1", content: "{}", isError: true)]),
        ]
        let tools = [LLMToolSpec(name: "get_thread", description: "Get one thread",
                                 inputSchemaJSON: #"{"type":"object"}"#)]
        let body = try decode(try AnthropicWire.requestBody(
            model: "claude-sonnet-5", messages: messages, tools: tools, maxTokens: 4096))

        XCTAssertEqual(body["system"] as? String, "be brief")
        XCTAssertEqual(body["max_tokens"] as? Int, 4096)
        let wireMessages = body["messages"] as! [[String: Any]]
        XCTAssertEqual(wireMessages.count, 3) // system hoisted out
        let assistantContent = wireMessages[1]["content"] as! [[String: Any]]
        XCTAssertEqual(assistantContent[0]["type"] as? String, "text")
        XCTAssertEqual(assistantContent[1]["type"] as? String, "tool_use")
        XCTAssertEqual(assistantContent[1]["id"] as? String, "tu1")
        let resultContent = wireMessages[2]["content"] as! [[String: Any]]
        XCTAssertEqual(resultContent[0]["type"] as? String, "tool_result")
        XCTAssertEqual(resultContent[0]["tool_use_id"] as? String, "tu1")
        XCTAssertEqual(resultContent[0]["is_error"] as? Bool, true)
        let toolDef = (body["tools"] as! [[String: Any]])[0]
        XCTAssertEqual(toolDef["name"] as? String, "get_thread")
        XCTAssertNotNil(toolDef["input_schema"])
    }

    func testStreamTextThenToolUseThenDone() {
        var state = AnthropicWire.StreamState()
        var events: [LLMEvent] = []
        events += state.consume(line: #"data: {"type":"message_start","message":{"usage":{"input_tokens":20}}}"#)
        events += state.consume(line: #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}"#)
        events += state.consume(line: #"data: {"type":"content_block_start","content_block":{"type":"tool_use","id":"tu2","name":"search_threads"}}"#)
        events += state.consume(line: #"data: {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{\"query\":"}}"#)
        events += state.consume(line: #"data: {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"\"acme\"}"}}"#)
        events += state.consume(line: #"data: {"type":"content_block_stop"}"#)
        events += state.consume(line: #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}"#)
        events += state.consume(line: #"data: {"type":"message_stop"}"#)
        XCTAssertEqual(events, [
            .token("Hi"),
            .toolCall(LLMToolCall(id: "tu2", name: "search_threads",
                                  argumentsJSON: #"{"query":"acme"}"#)),
            .done(stopReason: "tool_use",
                  usage: LLMUsage(promptTokens: 20, completionTokens: 9)),
        ])
    }

    func testEventAndBlankLinesAreIgnored() {
        var state = AnthropicWire.StreamState()
        XCTAssertEqual(state.consume(line: "event: content_block_delta"), [])
        XCTAssertEqual(state.consume(line: ""), [])
    }

    func testDataFieldWithoutSpaceAndTrailingCarriageReturn() {
        var state = AnthropicWire.StreamState()
        var events: [LLMEvent] = []
        events += state.consume(line: #"data:{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}"# + "\r")
        events += state.consume(line: #"data:{"type":"message_stop"}"# + "\r")
        XCTAssertEqual(events, [
            .token("Hi"),
            .done(stopReason: "end_turn",
                  usage: LLMUsage(promptTokens: 0, completionTokens: 0)),
        ])
    }
    func testStreamEmitsThinkingDeltasAsReasoning() {
        var state = AnthropicWire.StreamState()
        let events = state.consume(
            line: #"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hmm"}}"#)
        XCTAssertEqual(events, [.reasoning("hmm")])
    }

}
