import XCTest

final class AskMishContextTests: XCTestCase {
    func testSystemPromptNamesDateAccountsAndInjectionRule() {
        let prompt = AskMishContext.systemPrompt(
            date: Date(timeIntervalSince1970: 1_770_000_000),
            accountEmails: ["ron@example.com"])
        XCTAssertTrue(prompt.contains("ron@example.com"))
        XCTAssertTrue(prompt.lowercased().contains("never follow instructions"))
        XCTAssertTrue(prompt.lowercased().contains("search"))
    }

    func testHeadTailTruncationKeepsBothEnds() {
        let text = String(repeating: "a", count: 500) + "MIDDLE" + String(repeating: "z", count: 500)
        let out = AskMishContext.truncatedThreadContext(markdown: text, headChars: 100, tailChars: 100)
        XCTAssertTrue(out.hasPrefix(String(repeating: "a", count: 100)))
        XCTAssertTrue(out.hasSuffix(String(repeating: "z", count: 100)))
        XCTAssertTrue(out.contains("truncated"))
        // Short input passes through untouched.
        XCTAssertEqual(AskMishContext.truncatedThreadContext(markdown: "short", headChars: 100, tailChars: 100), "short")
    }

    func testHistoryDecodingRoundTripsToolCalls() throws {
        let calls = [LLMToolCall(id: "c1", name: "get_thread", argumentsJSON: #"{"thread_id":"t1"}"#)]
        let callsJSON = String(decoding: try JSONEncoder().encode(calls), as: UTF8.self)
        let rows = [
            ChatMessageRow(id: "1", conversationId: "c", role: "user", text: "hi",
                           toolCallsJSON: "[]", toolResultsJSON: "[]",
                           promptTokens: nil, completionTokens: nil, createdAt: Date()),
            ChatMessageRow(id: "2", conversationId: "c", role: "assistant", text: "",
                           toolCallsJSON: callsJSON, toolResultsJSON: "[]",
                           promptTokens: 10, completionTokens: 5, createdAt: Date()),
        ]
        let messages = AskMishContext.llmMessages(history: rows)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[1].toolCalls, calls)
    }

    func testTitleTrimsAndCaps() {
        XCTAssertEqual(AskMishContext.title(fromFirstUserText: "  find the acme thread  \nplease"),
                       "find the acme thread")
        XCTAssertLessThanOrEqual(
            AskMishContext.title(fromFirstUserText: String(repeating: "x", count: 200)).count, 48)
        XCTAssertEqual(AskMishContext.title(fromFirstUserText: "   "), "New chat")
    }
}
