import XCTest

/// Stub tool provider for pure JSON-RPC dispatch tests.
private final class StubTools: MCPToolProvider, @unchecked Sendable {
    var listAccountsResult: Result<String, Error> = .success("[]")
    var listThreadsResult: Result<String, Error> = .success("[]")
    var searchResult: Result<String, Error> = .success("[]")
    var getThreadResult: Result<String, Error> = .success("# t")
    var listDraftsResult: Result<String, Error> = .success("[]")
    var createDraftResult: Result<String, Error> = .success("{}")
    var setSummaryResult: Result<String, Error> = .success("{}")
    var listVIPsResult: Result<String, Error> = .success("[]")
    var addVIPResult: Result<String, Error> = .success("{}")
    var addVIPsResult: Result<String, Error> = .success("{}")
    var setVIPGroupsResult: Result<String, Error> = .success("{}")
    var removeVIPResult: Result<String, Error> = .success("{}")

    var lastListThreads: (mailbox: String, unreadOnly: Bool?, limit: Int, account: String?)?
    var lastCreateDraft: (account: String, to: [String], subject: String)?
    var lastAddVIP: (email: String, group: String?, groups: [String]?)?
    var lastAddVIPs: (emails: [String], group: String?, groups: [String]?)?
    var lastSetVIPGroups: (email: String, groups: [String])?

    func listAccounts() async throws -> String { try listAccountsResult.get() }
    func listThreads(mailbox: String, unreadOnly: Bool?, limit: Int, offset: Int, account: String?) async throws -> String {
        lastListThreads = (mailbox, unreadOnly, limit, account)
        return try listThreadsResult.get()
    }
    func searchThreads(query: String, limit: Int, offset: Int) async throws -> String { try searchResult.get() }
    func getThread(threadId: String) async throws -> String { try getThreadResult.get() }
    func listDrafts(account: String?) async throws -> String { try listDraftsResult.get() }
    func createDraft(
        account: String, to: [String], cc: [String]?, bcc: [String]?,
        subject: String, body: String, replyToThreadId: String?
    ) async throws -> String {
        lastCreateDraft = (account, to, subject)
        return try createDraftResult.get()
    }
    func setThreadSummary(threadId: String, summary: String, model: String) async throws -> String {
        try setSummaryResult.get()
    }
    func clearThreadSummary(threadId: String) async throws -> String { "{}" }
    func listVIPs() async throws -> String { try listVIPsResult.get() }
    func addVIP(email: String, group: String?, groups: [String]?) async throws -> String {
        lastAddVIP = (email, group, groups)
        return try addVIPResult.get()
    }
    func addVIPs(emails: [String], group: String?, groups: [String]?) async throws -> String {
        lastAddVIPs = (emails, group, groups)
        return try addVIPsResult.get()
    }
    func setVIPGroups(email: String, groups: [String]) async throws -> String {
        lastSetVIPGroups = (email, groups)
        return try setVIPGroupsResult.get()
    }
    func removeVIP(email: String) async throws -> String { try removeVIPResult.get() }
}

final class MCPRouterTests: XCTestCase {

    private func rpc(_ method: String, id: Any = 1, params: [String: Any]? = nil) -> Data {
        var obj: [String: Any] = ["jsonrpc": "2.0", "method": method, "id": id]
        if let params { obj["params"] = params }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    private func jsonObject(_ data: Data?) throws -> [String: Any] {
        let data = try XCTUnwrap(data)
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [String: Any])
    }

    func testInitializeHandshake() async throws {
        let tools = StubTools()
        let (status, body) = await MCPRouter.handle(
            body: rpc("initialize"), tools: tools, serverVersion: "9.9.9")
        XCTAssertEqual(status, 200)
        let obj = try jsonObject(body)
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        let caps = try XCTUnwrap(result["capabilities"] as? [String: Any])
        XCTAssertNotNil(caps["tools"])
        let info = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(info["name"] as? String, "mishmail")
        XCTAssertEqual(info["version"] as? String, "9.9.9")
    }

    func testNotificationsInitializedReturns202Empty() async throws {
        let tools = StubTools()
        // Notification: no id
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "method": "notifications/initialized",
        ])
        let (status, json) = await MCPRouter.handle(body: body, tools: tools)
        XCTAssertEqual(status, 202)
        XCTAssertNil(json)
    }

    func testPing() async throws {
        let (status, body) = await MCPRouter.handle(body: rpc("ping"), tools: StubTools())
        XCTAssertEqual(status, 200)
        let obj = try jsonObject(body)
        XCTAssertNotNil(obj["result"])
        XCTAssertNil(obj["error"])
    }

    func testToolsListReturnsEveryToolWithSchemas() async throws {
        let (status, body) = await MCPRouter.handle(body: rpc("tools/list"), tools: StubTools())
        XCTAssertEqual(status, 200)
        let obj = try jsonObject(body)
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 13)
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, [
            "list_accounts", "list_threads", "search_threads", "get_thread",
            "list_drafts", "create_draft", "set_thread_summary",
            "clear_thread_summary", "list_vips", "add_vip", "add_vips",
            "set_vip_groups", "remove_vip",
        ])
        for tool in tools {
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertNotNil(schema["properties"])
            XCTAssertFalse((tool["description"] as? String ?? "").isEmpty)
        }
    }

    func testAddVIPDispatchesGroupsArray() async throws {
        let stub = StubTools()
        let body = rpc("tools/call", params: [
            "name": "add_vip",
            "arguments": [
                "email": "Ada@Example.org",
                "groups": ["investors", "board"],
            ] as [String: Any],
        ])
        _ = await MCPRouter.handle(body: body, tools: stub)
        XCTAssertEqual(stub.lastAddVIP?.email, "Ada@Example.org")
        XCTAssertNil(stub.lastAddVIP?.group)
        XCTAssertEqual(stub.lastAddVIP?.groups, ["investors", "board"])
    }

    func testAddVIPsBulkDispatch() async throws {
        let stub = StubTools()
        let body = rpc("tools/call", params: [
            "name": "add_vips",
            "arguments": [
                "emails": ["a@x.com", "b@x.com"],
                "group": "family",
                "groups": ["friends"],
            ] as [String: Any],
        ])
        _ = await MCPRouter.handle(body: body, tools: stub)
        XCTAssertEqual(stub.lastAddVIPs?.emails, ["a@x.com", "b@x.com"])
        XCTAssertEqual(stub.lastAddVIPs?.group, "family")
        XCTAssertEqual(stub.lastAddVIPs?.groups, ["friends"])
    }

    func testSetVIPGroupsDispatch() async throws {
        let stub = StubTools()
        let body = rpc("tools/call", params: [
            "name": "set_vip_groups",
            "arguments": [
                "email": "a@x.com",
                "groups": ["work", "family"],
            ] as [String: Any],
        ])
        _ = await MCPRouter.handle(body: body, tools: stub)
        XCTAssertEqual(stub.lastSetVIPGroups?.email, "a@x.com")
        XCTAssertEqual(stub.lastSetVIPGroups?.groups, ["work", "family"])
    }

    func testAddVIPsRequiresEmails() async throws {
        let body = rpc("tools/call", params: [
            "name": "add_vips",
            "arguments": [:] as [String: Any],
        ])
        let (status, data) = await MCPRouter.handle(body: body, tools: StubTools())
        XCTAssertEqual(status, 200)
        let obj = try jsonObject(data)
        let error = try XCTUnwrap(obj["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    func testToolsCallDispatch() async throws {
        let stub = StubTools()
        stub.listAccountsResult = .success(#"[{"id":"a@x.com"}]"#)
        let body = rpc("tools/call", params: [
            "name": "list_accounts",
            "arguments": [:] as [String: Any],
        ])
        let (status, data) = await MCPRouter.handle(body: body, tools: stub)
        XCTAssertEqual(status, 200)
        let obj = try jsonObject(data)
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        XCTAssertEqual(content.first?["text"] as? String, #"[{"id":"a@x.com"}]"#)
    }

    func testToolsCallListThreadsArgs() async throws {
        let stub = StubTools()
        let body = rpc("tools/call", params: [
            "name": "list_threads",
            "arguments": [
                "mailbox": "inbox",
                "unread_only": true,
                "limit": 5,
                "account": "ron@x.com",
            ] as [String: Any],
        ])
        _ = await MCPRouter.handle(body: body, tools: stub)
        XCTAssertEqual(stub.lastListThreads?.mailbox, "inbox")
        XCTAssertEqual(stub.lastListThreads?.unreadOnly, true)
        XCTAssertEqual(stub.lastListThreads?.limit, 5)
        XCTAssertEqual(stub.lastListThreads?.account, "ron@x.com")
    }

    func testUnknownMethod() async throws {
        let (status, data) = await MCPRouter.handle(body: rpc("nope"), tools: StubTools())
        XCTAssertEqual(status, 200)
        let obj = try jsonObject(data)
        let error = try XCTUnwrap(obj["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
    }

    func testParseError() async throws {
        let (status, data) = await MCPRouter.handle(
            body: Data("not-json".utf8), tools: StubTools())
        XCTAssertEqual(status, 200)
        let obj = try jsonObject(data)
        let error = try XCTUnwrap(obj["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32700)
    }

    func testToolExecutionErrorIsErrorResult() async throws {
        let stub = StubTools()
        stub.getThreadResult = .failure(MCPToolError("Thread not found: x"))
        let body = rpc("tools/call", params: [
            "name": "get_thread",
            "arguments": ["thread_id": "x"] as [String: Any],
        ])
        let (status, data) = await MCPRouter.handle(body: body, tools: stub)
        XCTAssertEqual(status, 200)
        let obj = try jsonObject(data)
        XCTAssertNil(obj["error"], "tool failures are MCP isError results, not JSON-RPC errors")
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertTrue((content.first?["text"] as? String ?? "").contains("Thread not found"))
    }

    func testInvalidParamsMissingMailbox() async throws {
        let body = rpc("tools/call", params: [
            "name": "list_threads",
            "arguments": [:] as [String: Any],
        ])
        let (status, data) = await MCPRouter.handle(body: body, tools: StubTools())
        XCTAssertEqual(status, 200)
        let obj = try jsonObject(data)
        let error = try XCTUnwrap(obj["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
    }
}
