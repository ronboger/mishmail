import Foundation

/// Pure JSON-RPC 2.0 dispatch for MCP Streamable HTTP.
///
/// No networking: takes a request body and an `MCPToolProvider`, returns an
/// HTTP status and optional JSON body. Tool execution failures become MCP
/// `isError` *results* (not JSON-RPC errors), per the MCP tools spec.
enum MCPRouter {

    /// Handle one JSON-RPC request body.
    ///
    /// - Returns: `(status, json)` where `json` is nil for empty 202 responses
    ///   (`notifications/initialized`). Status is 200 for normal RPC, 202 for
    ///   accepted notifications, and still 200 for JSON-RPC error envelopes.
    static func handle(
        body: Data,
        tools: any MCPToolProvider,
        serverVersion: String = defaultServerVersion
    ) async -> (status: Int, json: Data?) {
        let envelope: JSONRPCRequest
        do {
            envelope = try JSONDecoder().decode(JSONRPCRequest.self, from: body)
        } catch {
            return (200, errorResponse(id: nil, code: -32700, message: "Parse error"))
        }

        let id = envelope.id
        let method = envelope.method

        // Notifications have no id and get 202 with empty body.
        if method == "notifications/initialized" {
            return (202, nil)
        }

        switch method {
        case "initialize":
            let result = InitializeResult(
                protocolVersion: MCPTools.protocolVersion,
                capabilities: InitializeCapabilities(tools: [:]),
                serverInfo: ServerInfo(name: MCPTools.serverName, version: serverVersion)
            )
            return (200, successResponse(id: id, result: result))

        case "ping":
            return (200, successResponse(id: id, result: EmptyObject()))

        case "tools/list":
            let toolsList = ToolsListResult(tools: MCPTools.catalog.map {
                ToolsListItem(name: $0.name, description: $0.description, inputSchema: $0.inputSchema)
            })
            return (200, successResponse(id: id, result: toolsList))

        case "tools/call":
            return await handleToolsCall(id: id, params: envelope.params, tools: tools)

        default:
            return (200, errorResponse(id: id, code: -32601, message: "Method not found"))
        }
    }

    // MARK: - tools/call

    private static func handleToolsCall(
        id: JSONRPCID?,
        params: JSONValue?,
        tools: any MCPToolProvider
    ) async -> (status: Int, json: Data?) {
        guard let params,
              case .object(let obj) = params,
              let nameVal = obj["name"],
              case .string(let name) = nameVal else {
            return (200, errorResponse(id: id, code: -32602, message: "Invalid params"))
        }

        let args: [String: JSONValue]
        if let a = obj["arguments"] {
            if case .object(let dict) = a {
                args = dict
            } else {
                return (200, errorResponse(id: id, code: -32602, message: "Invalid params"))
            }
        } else {
            args = [:]
        }

        do {
            let text = try await dispatch(name: name, args: args, tools: tools)
            let result = ToolCallResult(
                content: [ToolContent(type: "text", text: text)],
                isError: false
            )
            return (200, successResponse(id: id, result: result))
        } catch let error as ToolDispatchError {
            switch error {
            case .unknownTool:
                return (200, errorResponse(id: id, code: -32602, message: "Unknown tool: \(name)"))
            case .invalidParams(let message):
                return (200, errorResponse(id: id, code: -32602, message: message))
            case .execution(let message):
                let result = ToolCallResult(
                    content: [ToolContent(type: "text", text: message)],
                    isError: true
                )
                return (200, successResponse(id: id, result: result))
            }
        } catch {
            let result = ToolCallResult(
                content: [ToolContent(type: "text", text: error.localizedDescription)],
                isError: true
            )
            return (200, successResponse(id: id, result: result))
        }
    }

    /// Argument / lookup failures raised by `dispatch`. Internal so the
    /// Ask Mish executor can map them onto chat tool results.
    enum ToolDispatchError: Error {
        case unknownTool
        case invalidParams(String)
        case execution(String)
    }

    /// One tool call, decoded args in, text result out.
    ///
    /// Internal (not private) on purpose: the Ask Mish panel runs its tool
    /// calls through this exact function, so in-app chat and external MCP
    /// clients share one implementation.
    static func dispatch(
        name: String,
        args: [String: JSONValue],
        tools: any MCPToolProvider
    ) async throws -> String {
        switch name {
        case "list_accounts":
            return try await tools.listAccounts()

        case "list_threads":
            guard let mailbox = stringArg(args, "mailbox") else {
                throw ToolDispatchError.invalidParams("mailbox is required")
            }
            let unread = boolArg(args, "unread_only")
            let limit = MCPTools.clampedLimit(intArg(args, "limit"))
            let account = stringArg(args, "account")
            return try await tools.listThreads(
                mailbox: mailbox, unreadOnly: unread, limit: limit,
                offset: MCPTools.clampedOffset(intArg(args, "offset")), account: account)

        case "search_threads":
            guard let query = stringArg(args, "query") else {
                throw ToolDispatchError.invalidParams("query is required")
            }
            let limit = MCPTools.clampedLimit(intArg(args, "limit"))
            return try await tools.searchThreads(
                query: query, limit: limit,
                offset: MCPTools.clampedOffset(intArg(args, "offset")))

        case "get_thread":
            guard let threadId = stringArg(args, "thread_id") else {
                throw ToolDispatchError.invalidParams("thread_id is required")
            }
            return try await tools.getThread(threadId: threadId)

        case "list_drafts":
            return try await tools.listDrafts(account: stringArg(args, "account"))

        case "create_draft":
            guard let account = stringArg(args, "account") else {
                throw ToolDispatchError.invalidParams("account is required")
            }
            guard let to = stringArrayArg(args, "to"), !to.isEmpty else {
                throw ToolDispatchError.invalidParams("to must be a non-empty array")
            }
            guard let subject = stringArg(args, "subject") else {
                throw ToolDispatchError.invalidParams("subject is required")
            }
            guard let body = stringArg(args, "body") else {
                throw ToolDispatchError.invalidParams("body is required")
            }
            let cc = stringArrayArg(args, "cc")
            let bcc = stringArrayArg(args, "bcc")
            let replyTo = stringArg(args, "reply_to_thread_id")
            return try await tools.createDraft(
                account: account, to: to, cc: cc, bcc: bcc,
                subject: subject, body: body, replyToThreadId: replyTo)

        case "set_thread_summary":
            guard let threadId = stringArg(args, "thread_id") else {
                throw ToolDispatchError.invalidParams("thread_id is required")
            }
            guard let summary = stringArg(args, "summary") else {
                throw ToolDispatchError.invalidParams("summary is required")
            }
            guard let model = stringArg(args, "model") else {
                throw ToolDispatchError.invalidParams("model is required")
            }
            return try await tools.setThreadSummary(
                threadId: threadId, summary: summary, model: model)

        case "clear_thread_summary":
            guard let threadId = stringArg(args, "thread_id") else {
                throw ToolDispatchError.invalidParams("thread_id is required")
            }
            return try await tools.clearThreadSummary(threadId: threadId)

        case "list_vips":
            return try await tools.listVIPs()

        case "add_vip":
            guard let email = stringArg(args, "email") else {
                throw ToolDispatchError.invalidParams("email is required")
            }
            return try await tools.addVIP(
                email: email,
                group: stringArg(args, "group"),
                groups: stringArrayArg(args, "groups"))

        case "add_vips":
            guard let emails = stringArrayArg(args, "emails"), !emails.isEmpty else {
                throw ToolDispatchError.invalidParams("emails must be a non-empty array")
            }
            return try await tools.addVIPs(
                emails: emails,
                group: stringArg(args, "group"),
                groups: stringArrayArg(args, "groups"))

        case "set_vip_groups":
            guard let email = stringArg(args, "email") else {
                throw ToolDispatchError.invalidParams("email is required")
            }
            guard let groups = stringArrayArg(args, "groups") else {
                throw ToolDispatchError.invalidParams("groups is required (use [] to clear)")
            }
            return try await tools.setVIPGroups(email: email, groups: groups)

        case "remove_vip":
            guard let email = stringArg(args, "email") else {
                throw ToolDispatchError.invalidParams("email is required")
            }
            return try await tools.removeVIP(email: email)

        default:
            throw ToolDispatchError.unknownTool
        }
    }

    // MARK: - Arg helpers

    private static func stringArg(_ args: [String: JSONValue], _ key: String) -> String? {
        guard let v = args[key], case .string(let s) = v else { return nil }
        return s
    }

    private static func intArg(_ args: [String: JSONValue], _ key: String) -> Int? {
        guard let v = args[key] else { return nil }
        switch v {
        case .int(let i): return i
        case .double(let d): return Int(d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    private static func boolArg(_ args: [String: JSONValue], _ key: String) -> Bool? {
        guard let v = args[key] else { return nil }
        switch v {
        case .bool(let b): return b
        default: return nil
        }
    }

    private static func stringArrayArg(_ args: [String: JSONValue], _ key: String) -> [String]? {
        guard let v = args[key], case .array(let arr) = v else { return nil }
        var out: [String] = []
        for item in arr {
            guard case .string(let s) = item else { return nil }
            out.append(s)
        }
        return out
    }

    // MARK: - Encoding

    static var defaultServerVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private static func successResponse<T: Encodable>(id: JSONRPCID?, result: T) -> Data? {
        let env = JSONRPCSuccess(jsonrpc: "2.0", id: id, result: result)
        return try? JSONEncoder().encode(env)
    }

    private static func errorResponse(id: JSONRPCID?, code: Int, message: String) -> Data? {
        let env = JSONRPCErrorEnvelope(
            jsonrpc: "2.0",
            id: id,
            error: JSONRPCErrorBody(code: code, message: message)
        )
        return try? JSONEncoder().encode(env)
    }
}

// MARK: - JSON-RPC types

enum JSONRPCID: Codable, Equatable {
    case string(String)
    case int(Int)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid id")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .null: try c.encodeNil()
        }
    }
}

/// Loose JSON value for params decoding.
enum JSONValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }
}

private struct JSONRPCRequest: Decodable {
    var jsonrpc: String?
    var id: JSONRPCID?
    var method: String
    var params: JSONValue?
}

private struct JSONRPCSuccess<T: Encodable>: Encodable {
    var jsonrpc: String
    var id: JSONRPCID?
    var result: T
}

private struct JSONRPCErrorEnvelope: Encodable {
    var jsonrpc: String
    var id: JSONRPCID?
    var error: JSONRPCErrorBody
}

private struct JSONRPCErrorBody: Encodable {
    var code: Int
    var message: String
}

private struct EmptyObject: Encodable {}

private struct InitializeResult: Encodable {
    var protocolVersion: String
    var capabilities: InitializeCapabilities
    var serverInfo: ServerInfo
}

private struct InitializeCapabilities: Encodable {
    var tools: [String: Bool]
}

private struct ServerInfo: Encodable {
    var name: String
    var version: String
}

private struct ToolsListResult: Encodable {
    var tools: [ToolsListItem]
}

private struct ToolsListItem: Encodable {
    var name: String
    var description: String
    var inputSchema: [String: AnyCodableJSON]
}

private struct ToolCallResult: Encodable {
    var content: [ToolContent]
    var isError: Bool
}

private struct ToolContent: Encodable {
    var type: String
    var text: String
}

/// Thrown by tool providers to produce an MCP `isError` result (not JSON-RPC error).
struct MCPToolError: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
