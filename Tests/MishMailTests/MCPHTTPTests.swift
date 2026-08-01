import XCTest

final class MCPHTTPTests: XCTestCase {

    func testParseCompleteRequest() {
        let raw = """
            POST /mcp HTTP/1.1\r
            Host: 127.0.0.1\r
            Content-Type: application/json\r
            Content-Length: 17\r
            Authorization: Bearer secret\r
            \r
            {"jsonrpc":"2.0"}
            """
        let req = MCPHTTP.parse(Data(raw.utf8))
        XCTAssertEqual(req?.method, "POST")
        XCTAssertEqual(req?.path, "/mcp")
        XCTAssertEqual(req?.headers["content-type"], "application/json")
        XCTAssertEqual(req?.headers["authorization"], "Bearer secret")
        XCTAssertEqual(String(data: req?.body ?? Data(), encoding: .utf8), #"{"jsonrpc":"2.0"}"#)
    }

    func testParseStripsQueryFromPath() {
        let raw = "GET /mcp?x=1 HTTP/1.1\r\nContent-Length: 0\r\n\r\n"
        let req = MCPHTTP.parse(Data(raw.utf8))
        XCTAssertEqual(req?.path, "/mcp")
    }

    func testParsePartialReturnsNil() {
        let partial = Data("POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}".utf8)
        XCTAssertNil(MCPHTTP.parse(partial), "body shorter than Content-Length")
        let noHeadersEnd = Data("POST /mcp HTTP/1.1\r\nContent-Length: 0\r\n".utf8)
        XCTAssertNil(MCPHTTP.parse(noHeadersEnd))
    }

    func testParseEmptyBodyWithoutContentLength() {
        let raw = "GET /mcp HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let req = MCPHTTP.parse(Data(raw.utf8))
        XCTAssertEqual(req?.method, "GET")
        XCTAssertEqual(req?.body.count, 0)
    }

    func testResponseFormatting() {
        let body = Data(#"{"ok":true}"#.utf8)
        let data = MCPHTTP.response(
            status: 200, reason: "OK", contentType: "application/json", body: body)
        let text = String(data: data, encoding: .utf8)!
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Length: \(body.count)\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{\"ok\":true}") || text.contains("\r\n\r\n{\"ok\":true}"))
        // Body is exact tail after blank line.
        let parts = data.split(separator: UInt8(0x0A), omittingEmptySubsequences: false)
        // Simpler: find \r\n\r\n
        let sep = Data([0x0D, 0x0A, 0x0D, 0x0A])
        let range = data.range(of: sep)!
        XCTAssertEqual(data.subdata(in: range.upperBound..<data.endIndex), body)
    }

    func testBearerTokenExtraction() {
        XCTAssertEqual(
            MCPHTTP.bearerToken(from: ["authorization": "Bearer abc123"]),
            "abc123")
        XCTAssertEqual(
            MCPHTTP.bearerToken(from: ["authorization": "bearer  tok "]),
            "tok")
        XCTAssertNil(MCPHTTP.bearerToken(from: ["authorization": "Basic x"]))
        XCTAssertNil(MCPHTTP.bearerToken(from: [:]))
        XCTAssertNil(MCPHTTP.bearerToken(from: ["authorization": "Bearer "]))
    }
}
