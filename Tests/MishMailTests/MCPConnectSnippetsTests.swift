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

final class MCPPaginationTests: XCTestCase {

    func testClampedOffsetFloorsAtZero() {
        XCTAssertEqual(MCPTools.clampedOffset(nil), 0)
        XCTAssertEqual(MCPTools.clampedOffset(-5), 0)
        XCTAssertEqual(MCPTools.clampedOffset(250), 250)
    }

    func testListAndSearchSchemasExposeOffset() {
        for name in ["list_threads", "search_threads"] {
            let tool = MCPTools.catalog.first { $0.name == name }
            XCTAssertNotNil(tool, "\(name) missing from catalog")
            guard case .object(let props)? = tool?.inputSchema["properties"] else {
                return XCTFail("\(name) has no properties object")
            }
            XCTAssertNotNil(props["offset"], "\(name) must accept offset")
        }
    }
}

final class MCPPrimaryMailboxTests: XCTestCase {

    /// The label-matching trick the `primary` filter relies on: pad both sides
    /// so a whole label matches and a prefix (CATEGORY_UPDATES_DIGEST) doesn't.
    func testPaddedLabelMatchIsWholeLabelOnly() {
        func hasLabel(_ labelIds: String, _ label: String) -> Bool {
            (" " + labelIds + " ").contains(" " + label + " ")
        }
        XCTAssertTrue(hasLabel("INBOX CATEGORY_UPDATES", "CATEGORY_UPDATES"))
        XCTAssertTrue(hasLabel("CATEGORY_UPDATES INBOX", "CATEGORY_UPDATES"))
        XCTAssertTrue(hasLabel("CATEGORY_UPDATES", "CATEGORY_UPDATES"))
        XCTAssertTrue(hasLabel("A CATEGORY_FORUMS B", "CATEGORY_FORUMS"))
        XCTAssertFalse(hasLabel("INBOX CATEGORY_UPDATES_DIGEST", "CATEGORY_UPDATES"))
        XCTAssertFalse(hasLabel("INBOX", "CATEGORY_UPDATES"))
    }
}
