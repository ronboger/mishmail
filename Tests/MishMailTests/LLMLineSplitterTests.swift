import XCTest

final class LLMLineSplitterTests: XCTestCase {
    private func lines(_ chunks: [String]) -> [String] {
        var splitter = LLMLineSplitter()
        var out: [String] = []
        for chunk in chunks { out += splitter.append(contentsOf: Array(chunk.utf8)) }
        if let tail = splitter.finish() { out.append(tail) }
        return out
    }

    func testUnicodeLineSeparatorsDoNotSplitALine() {
        let event = "data: {\"a\":\"x\u{2028}y\u{2029}z\u{0085}w\"}"
        XCTAssertEqual(lines([event + "\n"]), [event])
    }

    func testSplitsOnLFAndCRLFAndLoneCR() {
        XCTAssertEqual(lines(["a\nb\r\nc\rd\n"]), ["a", "b", "c", "d"])
    }

    func testBlankLinesAreDropped() {
        XCTAssertEqual(lines(["event: x\ndata: 1\n\n\r\n\r\ndata: 2\n"]),
                       ["event: x", "data: 1", "data: 2"])
    }

    func testLineSplitAcrossChunksIsJoined() {
        XCTAssertEqual(lines(["data: {\"te", "xt\":\"hi\"}", "\ndata: 2\n"]),
                       ["data: {\"text\":\"hi\"}", "data: 2"])
    }

    func testMultiByteCharacterSplitAcrossChunksSurvives() {
        var splitter = LLMLineSplitter()
        let bytes = Array("é\u{2028}!\n".utf8)
        var out: [String] = []
        // One byte per chunk, so every multi-byte scalar is cut in the middle.
        for byte in bytes { out += splitter.append(contentsOf: [byte]) }
        XCTAssertEqual(out, ["é\u{2028}!"])
    }

    func testUnterminatedTailComesFromFinish() {
        XCTAssertEqual(lines(["a\nlast"]), ["a", "last"])
        var empty = LLMLineSplitter()
        XCTAssertNil(empty.finish())
    }

    /// The defect end to end: a text delta that carries a raw U+2028 must
    /// reach the Anthropic codec as one event.
    func testAnthropicDeltaWithLineSeparatorParsesAsOneToken() {
        let event = #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"one"#
            + "\u{2028}" + #"two"}}"#
        var state = AnthropicWire.StreamState()
        var events: [LLMEvent] = []
        for line in lines([event + "\n\n"]) { events += state.consume(line: line) }
        XCTAssertEqual(events, [.token("one\u{2028}two")])
    }

    /// Tool arguments cut by a separator used to become invalid JSON.
    func testAnthropicToolArgumentsWithLineSeparatorStayValidJSON() throws {
        let body = [
            #"data: {"type":"content_block_start","content_block":{"type":"tool_use","id":"tu1","name":"create_draft"}}"#,
            #"data: {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{\"body\":\"a"#
                + "\u{2028}" + #"b\"}"}}"#,
            #"data: {"type":"content_block_stop"}"#,
        ].joined(separator: "\r\n") + "\r\n"
        var state = AnthropicWire.StreamState()
        var events: [LLMEvent] = []
        for line in lines([body]) { events += state.consume(line: line) }
        guard case .toolCall(let call)? = events.first else { return XCTFail("no tool call") }
        let args = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(call.argumentsJSON.utf8)) as? [String: Any])
        XCTAssertEqual(args["body"] as? String, "a\u{2028}b")
    }
}
