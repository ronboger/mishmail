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

        let system = body["system"] as! [[String: Any]]
        XCTAssertEqual(system[0]["text"] as? String, "be brief")
        XCTAssertEqual((system[0]["cache_control"] as! [String: Any])["type"] as? String,
                       "ephemeral")
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
        XCTAssertEqual((resultContent[0]["cache_control"] as! [String: Any])["type"] as? String,
                       "ephemeral")
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

    func testRequestBodyOmitsThinkingByDefault() throws {
        let body = try decode(try AnthropicWire.requestBody(
            model: "claude-sonnet-5", messages: [LLMMessage(role: .user, text: "hi")],
            tools: [], maxTokens: 4096))
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["output_config"])
        XCTAssertEqual(body["max_tokens"] as? Int, 4096)
    }

    func testRequestBodySendsAdaptiveThinkingAndEffort() throws {
        let body = try decode(try AnthropicWire.requestBody(
            model: "claude-opus-4-6", messages: [LLMMessage(role: .user, text: "hi")],
            tools: [], maxTokens: 4096, thinking: .level("high")))
        let thinking = body["thinking"] as! [String: Any]
        XCTAssertEqual(thinking["type"] as? String, "adaptive")
        XCTAssertEqual((body["output_config"] as! [String: Any])["effort"] as? String, "high")
    }

    func testRequestBodyMapsXhighToMaxOnClaude46() throws {
        let body = try decode(try AnthropicWire.requestBody(
            model: "claude-sonnet-4-6", messages: [LLMMessage(role: .user, text: "hi")],
            tools: [], maxTokens: 4096, thinking: .level("xhigh")))
        XCTAssertEqual((body["output_config"] as! [String: Any])["effort"] as? String, "max")
    }

    func testRequestBodySendsBudgetThinkingOnClaude45() throws {
        let body = try decode(try AnthropicWire.requestBody(
            model: "claude-sonnet-4-5", messages: [LLMMessage(role: .user, text: "hi")],
            tools: [], maxTokens: 4096, thinking: .level("low")))
        let thinking = body["thinking"] as! [String: Any]
        XCTAssertEqual(thinking["type"] as? String, "enabled")
        XCTAssertEqual(thinking["budget_tokens"] as? Int, 2_048)
        XCTAssertEqual(body["max_tokens"] as? Int, 16_384)
    }

    func testRequestBodyRaisesMaxTokensWhenBudgetWouldNotFit() throws {
        let body = try decode(try AnthropicWire.requestBody(
            model: "claude-sonnet-4-5", messages: [LLMMessage(role: .user, text: "hi")],
            tools: [], maxTokens: 4096, thinking: .level("high")))
        let thinking = body["thinking"] as! [String: Any]
        XCTAssertEqual(thinking["budget_tokens"] as? Int, 16_384)
        XCTAssertEqual(body["max_tokens"] as? Int, 32_768)
    }

    func testBudgetThinkingAlwaysStaysBelowCappedOutput() throws {
        let body = try decode(try AnthropicWire.requestBody(
            model: "claude-opus-4-1", messages: [LLMMessage(role: .user, text: "hi")],
            tools: [], maxTokens: 8192, thinking: .level("xhigh")))
        let thinking = body["thinking"] as! [String: Any]
        XCTAssertLessThan(thinking["budget_tokens"] as! Int, body["max_tokens"] as! Int)
    }

    func testRequestBodyDisablesThinking() throws {
        let body = try decode(try AnthropicWire.requestBody(
            model: "claude-sonnet-5", messages: [LLMMessage(role: .user, text: "hi")],
            tools: [], maxTokens: 4096, thinking: .off))
        XCTAssertEqual((body["thinking"] as! [String: Any])["type"] as? String, "disabled")
    }

    func testRequestBodyOmitsOffOnFable() throws {
        let body = try decode(try AnthropicWire.requestBody(
            model: "claude-fable-5-1", messages: [LLMMessage(role: .user, text: "hi")],
            tools: [], maxTokens: 4096, thinking: .off))
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["output_config"])
    }

    func testRequestBodyOmitsOffOnPreAdaptiveClaude() throws {
        let body = try decode(try AnthropicWire.requestBody(
            model: "claude-sonnet-4-5", messages: [LLMMessage(role: .user, text: "hi")],
            tools: [], maxTokens: 4096, thinking: .off))
        XCTAssertNil(body["thinking"])
    }

    func testRequestBodyReplaysThinkingBlocksBeforeToolUse() throws {
        let block = LLMThinkingBlock(thinking: "plan", signature: "sig-1")
        let messages: [LLMMessage] = [
            LLMMessage(role: .user, text: "search"),
            LLMMessage(role: .assistant, text: "",
                       toolCalls: [LLMToolCall(id: "tu1", name: "search_threads",
                                               argumentsJSON: #"{"query":"acme"}"#)],
                       thinkingBlocks: [block]),
            LLMMessage(role: .tool, text: "",
                       toolResults: [LLMToolResult(callID: "tu1", content: "[]", isError: false)]),
        ]
        let body = try decode(try AnthropicWire.requestBody(
            model: "claude-sonnet-5", messages: messages, tools: [], maxTokens: 4096,
            thinking: .level("high")))
        let wire = body["messages"] as! [[String: Any]]
        let assistantContent = wire[1]["content"] as! [[String: Any]]
        XCTAssertEqual(assistantContent[0]["type"] as? String, "thinking")
        XCTAssertEqual(assistantContent[0]["thinking"] as? String, "plan")
        XCTAssertEqual(assistantContent[0]["signature"] as? String, "sig-1")
        XCTAssertEqual(assistantContent[1]["type"] as? String, "tool_use")
    }

    func testRequestBodyDropsUnsignedThinkingAndEmptyRedactedBlocks() throws {
        let messages = [LLMMessage(
            role: .assistant, text: "answer",
            thinkingBlocks: [
                LLMThinkingBlock(thinking: "replayed", signature: ""),
                LLMThinkingBlock(thinking: "", signature: "", redactedData: ""),
                LLMThinkingBlock(thinking: "kept", signature: "sig"),
            ])]
        let body = try decode(try AnthropicWire.requestBody(
            model: "claude-sonnet-5", messages: messages, tools: [], maxTokens: 4096))
        let content = (body["messages"] as! [[String: Any]])[0]["content"] as! [[String: Any]]
        XCTAssertEqual(content.count, 2) // signed thinking + text
        XCTAssertEqual(content[0]["signature"] as? String, "sig")
        XCTAssertEqual(content[1]["text"] as? String, "answer")
    }

    func testStreamEmitsThinkingBlockWithSignature() {
        var state = AnthropicWire.StreamState()
        var events: [LLMEvent] = []
        events += state.consume(line: #"data: {"type":"content_block_start","content_block":{"type":"thinking"}}"#)
        events += state.consume(line: #"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"plan"}}"#)
        events += state.consume(line: #"data: {"type":"content_block_delta","delta":{"type":"signature_delta","signature":"sig-1"}}"#)
        events += state.consume(line: #"data: {"type":"content_block_stop"}"#)
        XCTAssertEqual(events, [
            .reasoning("plan"),
            .thinkingBlock(LLMThinkingBlock(thinking: "plan", signature: "sig-1")),
        ])
    }

    func testRequestBodyOmitsThinkingOnModelsThatCannotThink() throws {
        let body = try decode(try AnthropicWire.requestBody(
            model: "claude-3-5-haiku", messages: [LLMMessage(role: .user, text: "hi")],
            tools: [], maxTokens: 4096, thinking: .level("high")))
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["output_config"])
    }

    func testStreamProviderErrorIsSurfaced() {
        var state = AnthropicWire.StreamState()
        XCTAssertEqual(
            state.consume(line: #"data: {"type":"error","error":{"message":"bad beta"}}"#),
            [.error("bad beta")])
    }

    func testStreamEndingWithoutMessageStopIsAnError() {
        var state = AnthropicWire.StreamState()
        _ = state.consume(line: #"data: {"type":"message_start","message":{"usage":{"input_tokens":1}}}"#)
        XCTAssertEqual(state.finalEvents(), [.error("stream ended early")])
    }

    func testStreamIncludesAnthropicCacheUsage() {
        var state = AnthropicWire.StreamState()
        _ = state.consume(line: #"data: {"type":"message_start","message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":4,"cache_read_input_tokens":6}}}"#)
        _ = state.consume(line: #"data: {"type":"message_delta","usage":{"output_tokens":3,"cache_read_input_tokens":7}}"#)
        let events = state.consume(line: #"data: {"type":"message_stop"}"#)
        XCTAssertEqual(events, [.done(stopReason: "end_turn",
                                      usage: LLMUsage(promptTokens: 10, completionTokens: 3,
                                                      cacheCreationInputTokens: 4,
                                                      cacheReadInputTokens: 7))])
    }


    // MARK: - Budget thinking answer room

    func testBudgetThinkingAtXhighLeavesAnswerRoomUnderCap() throws {
        // Opus 4.1: 32k cap. The old code sent budget = cap - 1.
        let body = try decode(try AnthropicWire.requestBody(
            model: "claude-opus-4-1", messages: [LLMMessage(role: .user, text: "hi")],
            tools: [], maxTokens: 8192, thinking: .level("xhigh")))
        let budget = (body["thinking"] as! [String: Any])["budget_tokens"] as! Int
        let maxTokens = body["max_tokens"] as! Int
        XCTAssertEqual(budget, 32_000 - 8_192)
        XCTAssertEqual(maxTokens, 32_000)
        XCTAssertGreaterThanOrEqual(maxTokens - budget, AnthropicWire.answerReserveTokens)
    }

    func testBudgetPlanKeepsFloorAndCapsMaxTokens() {
        let tiny = AnthropicWire.budgetPlan(level: "xhigh", maxTokens: 4_096, cap: 8_192)
        XCTAssertEqual(tiny.budget, 1_024)
        XCTAssertEqual(tiny.maxTokens, 8_192)
        let roomy = AnthropicWire.budgetPlan(level: "medium", maxTokens: 4_096, cap: 64_000)
        XCTAssertEqual(roomy.budget, 8_192)
        XCTAssertEqual(roomy.maxTokens, 16_384)
        let big = AnthropicWire.budgetPlan(level: "high", maxTokens: 32_768, cap: 64_000)
        XCTAssertEqual(big.budget, 16_384)
        XCTAssertEqual(big.maxTokens, 32_768)
    }

    // MARK: - tool_choice none

    private var toolHistory: [LLMMessage] {
        [
            LLMMessage(role: .user, text: "find acme"),
            LLMMessage(role: .assistant, text: "", toolCalls: [
                LLMToolCall(id: "tu1", name: "search_threads", argumentsJSON: "{}")]),
            LLMMessage(role: .tool, text: "", toolResults: [
                LLMToolResult(callID: "tu1", content: "[]", isError: false)]),
        ]
    }

    private var toolSpecs: [LLMToolSpec] {
        [LLMToolSpec(name: "search_threads", description: "Search",
                     inputSchemaJSON: #"{"type":"object"}"#)]
    }

    func testToolChoiceNoneKeepsToolsAndForbidsCalls() throws {
        let body = try decode(try AnthropicWire.requestBody(
            model: "claude-sonnet-5", messages: toolHistory, tools: toolSpecs,
            maxTokens: 4096, toolChoiceNone: true))
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((body["tool_choice"] as? [String: Any])?["type"] as? String, "none")
    }

    func testToolChoiceOmittedByDefault() throws {
        let body = try decode(try AnthropicWire.requestBody(
            model: "claude-sonnet-5", messages: toolHistory, tools: toolSpecs,
            maxTokens: 4096))
        XCTAssertNil(body["tool_choice"])
    }
}
