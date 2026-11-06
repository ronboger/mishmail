import XCTest

final class LLMWireResponsesTests: XCTestCase {
    private func decode(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testToolCallsOnGPT61UseResponses() {
        XCTAssertTrue(OpenAIResponses.usesResponses(
            host: "api.openai.com", model: "gpt-6.1-sol",
            hasTools: true, thinking: .off))
        XCTAssertTrue(OpenAIResponses.usesResponses(
            host: "api.openai.com", model: "openai/gpt-6.1-sol",
            hasTools: true, thinking: .level("high")))
        XCTAssertFalse(OpenAIResponses.usesResponses(
            host: "api.openai.com", model: "gpt-6.1-sol",
            hasTools: false, thinking: .level("high")))
        XCTAssertFalse(OpenAIResponses.usesResponses(
            host: "api.x.ai", model: "gpt-6.1-sol",
            hasTools: true, thinking: .level("high")))
    }

    func testGPT6SolToolsStayOnChatCompletionsWhenReasoningIsOff() {
        XCTAssertFalse(OpenAIResponses.usesResponses(
            host: "api.openai.com", model: "gpt-6-sol",
            hasTools: true, thinking: .off))
        XCTAssertTrue(OpenAIResponses.usesResponses(
            host: "api.openai.com", model: "gpt-6-sol",
            hasTools: true, thinking: .off, chatGPTSubscription: true))
        XCTAssertTrue(OpenAIResponses.usesResponses(
            host: "api.openai.com", model: "gpt-6-luna",
            hasTools: true, thinking: .off, chatGPTSubscription: true))
        XCTAssertTrue(OpenAIResponses.usesResponses(
            host: "api.openai.com", model: "gpt-6-luna",
            hasTools: true, thinking: .modelDefault))
        XCTAssertTrue(OpenAIResponses.usesResponses(
            host: "api.openai.com", model: "gpt-6-sol",
            hasTools: true, thinking: .level("xhigh")))
    }

    func testRequestBodyMapsInstructionsToolsAndReasoning() throws {
        let messages: [LLMMessage] = [
            LLMMessage(role: .system, text: "be brief"),
            LLMMessage(role: .user, text: "hi"),
            LLMMessage(role: .assistant, text: "looking",
                       toolCalls: [LLMToolCall(id: "c1", name: "search_threads",
                                               argumentsJSON: #"{"query":"acme"}"#)]),
            LLMMessage(role: .tool, text: "",
                       toolResults: [LLMToolResult(callID: "c1", content: "[]", isError: false)]),
        ]
        let tools = [LLMToolSpec(name: "search_threads", description: "Search mail",
                                 inputSchemaJSON: #"{"type":"object"}"#)]
        let body = try decode(try OpenAIResponses.requestBody(
            model: "gpt-6.1-sol", messages: messages, tools: tools,
            thinking: .level("xhigh")))
        XCTAssertEqual(body["model"] as? String, "gpt-6.1-sol")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["instructions"] as? String, "be brief")
        XCTAssertEqual(body["include"] as? [String], ["reasoning.encrypted_content"])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "xhigh")
        let input = body["input"] as! [[String: Any]]
        XCTAssertEqual(input.map { $0["type"] as? String ?? $0["role"] as? String },
                       ["user", "assistant", "function_call", "function_call_output"])
        XCTAssertEqual(input[2]["call_id"] as? String, "c1")
        XCTAssertEqual(input[2]["name"] as? String, "search_threads")
        XCTAssertEqual(input[3]["call_id"] as? String, "c1")
        let tool = (body["tools"] as! [[String: Any]])[0]
        XCTAssertEqual(tool["type"] as? String, "function")
        XCTAssertEqual(tool["name"] as? String, "search_threads")
        XCTAssertEqual(tool["strict"] as? Bool, false)
    }

    func testReasoningItemIsReplayedBeforeTheNextToolCall() throws {
        var state = OpenAIResponses.StreamState()
        let item = #"{"type":"response.output_item.done","output_index":0,"item":{"id":"rs_1","type":"reasoning","encrypted_content":"abc","summary":[]}}"#
        let events = state.consume(line: "data: \(item)")
        guard case .thinkingBlock(let block) = events.first else {
            return XCTFail("expected a reasoning item")
        }
        let messages = [
            LLMMessage(role: .assistant, text: "",
                       toolCalls: [LLMToolCall(id: "c1", name: "search_threads",
                                               argumentsJSON: "{}")],
                       thinkingBlocks: [block]),
        ]
        let body = try decode(try OpenAIResponses.requestBody(
            model: "gpt-6.1-sol", messages: messages, tools: [], thinking: .level("low")))
        let input = body["input"] as! [[String: Any]]
        XCTAssertEqual(input.first?["type"] as? String, "reasoning")
        XCTAssertEqual(input.first?["id"] as? String, "rs_1")
        XCTAssertEqual(input.first?["encrypted_content"] as? String, "abc")
        XCTAssertEqual(input.last?["type"] as? String, "function_call")
    }

    func testReasoningItemStaysInsideTheCurrentTurn() throws {
        let block = LLMThinkingBlock(responsesItemJSON:
            #"{"id":"rs_1","type":"reasoning","encrypted_content":"abc"}"#)
        let call = LLMToolCall(id: "c1", name: "search_threads", argumentsJSON: "{}")
        let oldTurn = [
            LLMMessage(role: .user, text: "first"),
            LLMMessage(role: .assistant, text: "", toolCalls: [call], thinkingBlocks: [block]),
            LLMMessage(role: .user, text: "next"),
        ]
        let oldBody = try decode(try OpenAIResponses.requestBody(
            model: "gpt-6.1-sol", messages: oldTurn, tools: [], thinking: .off))
        let oldInput = oldBody["input"] as! [[String: Any]]
        XCTAssertFalse(oldInput.contains { $0["type"] as? String == "reasoning" })

        let currentTurn = [
            LLMMessage(role: .user, text: "first"),
            LLMMessage(role: .assistant, text: "", toolCalls: [call], thinkingBlocks: [block]),
        ]
        let currentBody = try decode(try OpenAIResponses.requestBody(
            model: "gpt-6.1-sol", messages: currentTurn, tools: [], thinking: .off))
        let currentInput = currentBody["input"] as! [[String: Any]]
        XCTAssertEqual(currentInput.map { $0["type"] as? String ?? $0["role"] as? String },
                       ["user", "reasoning", "function_call"])
    }

    func testProviderChangeDropsCurrentTurnReasoning() {
        let block = LLMThinkingBlock(responsesItemJSON:
            #"{"id":"rs_1","type":"reasoning"}"#)
        let kept = LLMThinkingBlock(thinking: "old", signature: "sig")
        let messages = [
            LLMMessage(role: .user, text: "first"),
            LLMMessage(role: .assistant, text: "done", thinkingBlocks: [block, kept]),
        ]
        let stripped = OpenAIResponses.withoutCurrentTurnReasoning(messages)
        XCTAssertTrue(stripped[1].thinkingBlocks.allSatisfy { $0.responsesItemJSON == nil })
        XCTAssertEqual(stripped[1].thinkingBlocks.first?.signature, "sig")
        XCTAssertEqual(stripped[1].text, "done")
    }

    func testGPT61OffBecomesLowBecauseNoneIsRejected() throws {
        let body = try decode(try OpenAIResponses.requestBody(
            model: "gpt-6.1-sol",
            messages: [LLMMessage(role: .user, text: "hi")],
            tools: [LLMToolSpec(name: "search_threads", description: "Search",
                                inputSchemaJSON: #"{"type":"object"}"#)],
            thinking: .off))
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "low")
    }

    func testChatCompletionsSendsNoneForGPT6SolToolsWhenOff() throws {
        let tools = [LLMToolSpec(name: "search_threads", description: "Search",
                                 inputSchemaJSON: #"{"type":"object"}"#)]
        let off = try decode(try OpenAIWire.requestBody(
            model: "gpt-6-sol",
            messages: [LLMMessage(role: .user, text: "hi")],
            tools: tools, thinking: .off))
        XCTAssertEqual(off["reasoning_effort"] as? String, "none")
        let gpt5 = try decode(try OpenAIWire.requestBody(
            model: "gpt-5",
            messages: [LLMMessage(role: .user, text: "hi")],
            tools: tools, thinking: .off))
        XCTAssertNil(gpt5["reasoning_effort"])
    }

    func testChatGPTSubscriptionUsesTheCodexBackend() throws {
        XCTAssertEqual(
            OpenAIResponses.endpoint(baseURL: "https://api.openai.com/v1",
                                     chatGPTSubscription: true),
            "https://chatgpt.com/backend-api/codex/responses")
        XCTAssertTrue(OpenAIResponses.usesResponses(
            host: "api.openai.com", model: "gpt-6.1-sol",
            hasTools: true, thinking: .level("high"), chatGPTSubscription: true))
        let body = try decode(try OpenAIResponses.requestBody(
            model: "gpt-6.1-sol",
            messages: [LLMMessage(role: .user, text: "hi")],
            tools: [LLMToolSpec(name: "search_threads", description: "Search",
                                inputSchemaJSON: #"{"type":"object"}"#)],
            thinking: .level("low"), codexBackend: true))
        XCTAssertEqual(body["store"] as? Bool, false)
        let payload: [String: Any] = [
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct_1"],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(OpenAIResponses.chatGPTAccountID(in: "e30.\(encoded).sig"), "acct_1")
        XCTAssertNil(OpenAIResponses.chatGPTAccountID(in: "not-a-token"))
    }

    func testEOFDoesNotReleaseAPartialToolCall() {
        var state = OpenAIResponses.StreamState()
        _ = state.consume(line: #"data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"c1","name":"search_threads"}}"#)
        _ = state.consume(line: #"data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":"{}"}"#)
        let events = state.abandon()
        XCTAssertEqual(events.count, 1)
        guard case .error = events.first else {
            return XCTFail("expected an error")
        }
        XCTAssertTrue(state.abandon().isEmpty)
    }

    func testPrematureTerminatorsNeverReleasePendingCalls() {
        for terminal in ["data: [DONE]", #"data: {"type":"response.incomplete","response":{}}"#] {
            var state = OpenAIResponses.StreamState()
            _ = state.consume(line: #"data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","call_id":"c","name":"send_draft","arguments":"{}"}}"#)
            let events = state.consume(line: terminal)
            XCTAssertFalse(events.contains { if case .toolCall = $0 { return true }; return false })
            XCTAssertTrue(state.consume(line: #"data: {"type":"response.completed"}"#).isEmpty)
        }
    }

    func testCompletedResponseSuppliesToolCallWithoutDeltas() {
        var state = OpenAIResponses.StreamState()
        let events = state.consume(line: #"data: {"type":"response.completed","response":{"output":[{"type":"function_call","call_id":"c","name":"search_threads","arguments":"{}"}]}}"#)
        XCTAssertEqual(events, [.toolCall(.init(id: "c", name: "search_threads", argumentsJSON: "{}")),
                                .done(stopReason: "tool_calls", usage: nil)])
    }

    func testSubscriptionTextOnlyRequestUsesSubscriptionBackend() {
        XCTAssertTrue(OpenAIResponses.usesResponses(
            host: "api.openai.com", model: "gpt-5", hasTools: false,
            thinking: .off, chatGPTSubscription: true))
    }

    func testStreamTextToolCallAndUsage() {
        var state = OpenAIResponses.StreamState()
        var events: [LLMEvent] = []
        events += state.consume(line: #"data: {"type":"response.output_text.delta","delta":"Hel"}"#)
        events += state.consume(line: #"data: {"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","call_id":"c1","name":"search_threads","arguments":""}}"#)
        events += state.consume(line: #"data: {"type":"response.function_call_arguments.delta","output_index":1,"delta":"{\"q\":"}"#)
        events += state.consume(line: #"data: {"type":"response.function_call_arguments.done","output_index":1,"arguments":"{\"q\":\"a\"}"}"#)
        events += state.consume(line: #"data: {"type":"response.completed","response":{"usage":{"input_tokens":12,"output_tokens":3,"input_tokens_details":{"cached_tokens":2}}}}"#)
        XCTAssertEqual(events, [
            .token("Hel"),
            .toolCall(LLMToolCall(id: "c1", name: "search_threads", argumentsJSON: #"{"q":"a"}"#)),
            .done(stopReason: "tool_calls", usage: LLMUsage(
                promptTokens: 12, completionTokens: 3, cacheReadInputTokens: 2)),
        ])
    }
}
