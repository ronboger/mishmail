import XCTest

final class LLMWireOllamaTests: XCTestCase {
    func testRequestBodyMapsMessagesAndTools() throws {
        let messages = [LLMMessage(role: .user, text: "hi")]
        let tools = [LLMToolSpec(name: "list_threads", description: "List",
                                 inputSchemaJSON: #"{"type":"object"}"#)]
        let body = try JSONSerialization.jsonObject(with: try OllamaChatWire.requestBody(
            model: "llama3.2", messages: messages, tools: tools)) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "llama3.2")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["messages"] as! [[String: Any]])[0]["content"] as? String, "hi")
        let function = ((body["tools"] as! [[String: Any]])[0]["function"]) as! [String: Any]
        XCTAssertEqual(function["name"] as? String, "list_threads")
    }

    func testStreamTokensToolCallAndDoneWithUsage() {
        var state = OllamaChatWire.StreamState()
        var events: [LLMEvent] = []
        events += state.consume(line: #"{"message":{"role":"assistant","content":"He"},"done":false}"#)
        events += state.consume(line: #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"list_threads","arguments":{"limit":5}}}]},"done":false}"#)
        events += state.consume(line: #"{"message":{"role":"assistant","content":""},"done":true,"prompt_eval_count":15,"eval_count":4}"#)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0], .token("He"))
        guard case .toolCall(let call) = events[1] else { return XCTFail("expected toolCall") }
        XCTAssertEqual(call.name, "list_threads")
        XCTAssertEqual(call.id, "call_0") // Ollama has no ids; codec synthesizes them
        let args = try! JSONSerialization.jsonObject(
            with: Data(call.argumentsJSON.utf8)) as! [String: Any]
        XCTAssertEqual(args["limit"] as? Int, 5)
        XCTAssertEqual(events[2], .done(stopReason: "stop",
                                        usage: LLMUsage(promptTokens: 15, completionTokens: 4)))
    }
}
