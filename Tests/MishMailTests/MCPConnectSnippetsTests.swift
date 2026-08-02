import XCTest

final class MCPConnectSnippetsTests: XCTestCase {

    func testEveryClientEmbedsURLAndToken() {
        for client in MCPConnectSnippets.Client.allCases {
            let s = MCPConnectSnippets.snippet(for: client, port: 41888, token: "tok123")
            XCTAssertTrue(s.contains("http://127.0.0.1:41888/mcp"), "\(client) missing URL")
            XCTAssertTrue(s.contains("Authorization: Bearer tok123"), "\(client) missing auth")
        }
    }

    func testClientCommandPrefixes() {
        func snippet(_ c: MCPConnectSnippets.Client) -> String {
            MCPConnectSnippets.snippet(for: c, port: 1, token: "t")
        }
        XCTAssertTrue(snippet(.claudeCode).hasPrefix("claude mcp add --transport http mishmail "))
        XCTAssertTrue(snippet(.codex).hasPrefix("codex mcp add mishmail -- npx -y mcp-remote "))
        XCTAssertTrue(snippet(.geminiCLI).hasPrefix("gemini mcp add --transport http mishmail "))
        XCTAssertTrue(snippet(.generic).hasPrefix("npx -y mcp-remote "))
    }
}
