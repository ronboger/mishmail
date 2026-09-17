import XCTest

final class LLMErrorBodyTests: XCTestCase {
    func testAnthropicShapeYieldsMessage() {
        let body = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"thinking.type: disabled is not supported"}}"#.utf8)
        XCTAssertEqual(LLMErrorBody.message(from: body), "thinking.type: disabled is not supported")
    }

    func testOllamaStringErrorYieldsMessage() {
        let body = Data(#"{"error":"model 'x' not found"}"#.utf8)
        XCTAssertEqual(LLMErrorBody.message(from: body), "model 'x' not found")
    }

    func testPlainTextFallsBackAndHTMLIsDropped() {
        XCTAssertEqual(LLMErrorBody.message(from: Data("  Bad Request\n".utf8)), "Bad Request")
        XCTAssertNil(LLMErrorBody.message(from: Data("<html><body>nope</body></html>".utf8)))
        XCTAssertNil(LLMErrorBody.message(from: Data()))
    }

    func testLongMessagesAreCapped() {
        let long = String(repeating: "a", count: 1_000)
        let body = Data(#"{"error":{"message":"\#(long)"}}"#.utf8)
        let message = LLMErrorBody.message(from: body)!
        XCTAssertEqual(message.count, LLMErrorBody.maxMessageChars + 1)
        XCTAssertTrue(message.hasSuffix("…"))
    }

    func testClientErrorDescriptionIncludesDetail() {
        XCTAssertEqual(LLMClientError.http(400, "bad field").errorDescription,
                       "The model provider returned HTTP 400: bad field")
        XCTAssertEqual(LLMClientError.http(500).errorDescription,
                       "The model provider returned HTTP 500.")
    }
}
