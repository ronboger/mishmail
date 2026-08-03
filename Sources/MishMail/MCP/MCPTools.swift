import Foundation

/// Tool surface exposed over MCP. Implementations may hop actors; the
/// router only needs async text results (or throws → `isError` content).
protocol MCPToolProvider: Sendable {
    func listAccounts() async throws -> String
    func listThreads(mailbox: String, unreadOnly: Bool?, limit: Int, offset: Int, account: String?) async throws -> String
    func searchThreads(query: String, limit: Int, offset: Int) async throws -> String
    func getThread(threadId: String) async throws -> String
    func listDrafts(account: String?) async throws -> String
    func createDraft(
        account: String, to: [String], cc: [String]?, bcc: [String]?,
        subject: String, body: String, replyToThreadId: String?
    ) async throws -> String
    func setThreadSummary(threadId: String, summary: String, model: String) async throws -> String
    func clearThreadSummary(threadId: String) async throws -> String
    func listVIPs() async throws -> String
    func addVIP(email: String, group: String?) async throws -> String
    func removeVIP(email: String) async throws -> String
}

/// Static tool catalog: names, descriptions, and JSON Schema input objects.
enum MCPTools {
    /// Protocol version advertised by `initialize`.
    static let protocolVersion = "2025-06-18"

    /// Default server name for `serverInfo`.
    static let serverName = "mishmail"

    /// Maximum rows returned by list/search tools.
    static let maxLimit = 100

    static let defaultLimit = 25

    /// Ordered tool definitions for `tools/list`.
    static let catalog: [ToolDefinition] = [
        ToolDefinition(
            name: "list_accounts",
            description: "List linked Gmail accounts (id/email and display name).",
            inputSchema: objectSchema(properties: [:], required: [])
        ),
        ToolDefinition(
            name: "list_threads",
            description: "List threads in a mailbox. Returns id, subject, snippet, from, date, flags, any persisted AI summary (summaryStale=true once the thread has new messages since it was written), and the on-device triage category when the app has classified the thread.",
            inputSchema: objectSchema(
                properties: [
                    "mailbox": stringSchema(
                        description: "One of: primary (inbox minus Promotions/Social — conversations that actually need attention), inbox, starred, sent, drafts, all"),
                    "unread_only": booleanSchema(description: "If true, only unread threads"),
                    "limit": integerSchema(description: "Max threads (1–100, default 25)"),
                    "offset": integerSchema(
                        description: "Skip this many threads — page through more than `limit` (default 0)"),
                    "account": stringSchema(description: "Optional account email filter"),
                ],
                required: ["mailbox"]
            )
        ),
        ToolDefinition(
            name: "search_threads",
            description: "Full-text search threads by subject/from (FTS5 with LIKE fallback).",
            inputSchema: objectSchema(
                properties: [
                    "query": stringSchema(description: "Search query"),
                    "limit": integerSchema(description: "Max threads (1–100, default 25)"),
                    "offset": integerSchema(description: "Skip this many matches (default 0)"),
                ],
                required: ["query"]
            )
        ),
        ToolDefinition(
            name: "get_thread",
            description: "Fetch a full thread as Markdown (hydrated bodies).",
            inputSchema: objectSchema(
                properties: [
                    "thread_id": stringSchema(description: "Local thread id (account:gmailThreadId)"),
                ],
                required: ["thread_id"]
            )
        ),
        ToolDefinition(
            name: "list_drafts",
            description: "List draft messages (DRAFT label), optionally for one account.",
            inputSchema: objectSchema(
                properties: [
                    "account": stringSchema(description: "Optional account email filter"),
                ],
                required: []
            )
        ),
        ToolDefinition(
            name: "create_draft",
            description: "Create a Gmail draft via MishMail (reviewable before send). Requires at least one recipient.",
            inputSchema: objectSchema(
                properties: [
                    "account": stringSchema(description: "Sending account email"),
                    "to": arrayOfStringsSchema(description: "To recipients"),
                    "cc": arrayOfStringsSchema(description: "Cc recipients"),
                    "bcc": arrayOfStringsSchema(description: "Bcc recipients"),
                    "subject": stringSchema(description: "Subject line"),
                    "body": stringSchema(description: "Plain-text / Markdown body"),
                    "reply_to_thread_id": stringSchema(
                        description: "Optional local thread id to reply on"),
                ],
                required: ["account", "to", "subject", "body"]
            )
        ),
        ToolDefinition(
            name: "set_thread_summary",
            description: "Upsert a persisted AI summary for a thread (shown in the reading pane).",
            inputSchema: objectSchema(
                properties: [
                    "thread_id": stringSchema(description: "Local thread id"),
                    "summary": stringSchema(description: "Summary text"),
                    "model": stringSchema(description: "Model that produced the summary"),
                ],
                required: ["thread_id", "summary", "model"]
            )
        ),
        ToolDefinition(
            name: "clear_thread_summary",
            description: "Delete a thread's persisted AI summary (e.g. when it has gone stale and won't be refreshed).",
            inputSchema: objectSchema(
                properties: [
                    "thread_id": stringSchema(description: "Local thread id"),
                ],
                required: ["thread_id"]
            )
        ),
        ToolDefinition(
            name: "list_vips",
            description: "List VIP senders with group membership and group enabled state.",
            inputSchema: objectSchema(properties: [:], required: [])
        ),
        ToolDefinition(
            name: "add_vip",
            description: "Add a VIP sender. Creates the group row if needed. Default group is \"Suggested\".",
            inputSchema: objectSchema(
                properties: [
                    "email": stringSchema(description: "Sender email address"),
                    "group": stringSchema(description: "VIP group name (default: Suggested)"),
                ],
                required: ["email"]
            )
        ),
        ToolDefinition(
            name: "remove_vip",
            description: "Remove a VIP sender by email.",
            inputSchema: objectSchema(
                properties: [
                    "email": stringSchema(description: "Sender email address"),
                ],
                required: ["email"]
            )
        ),
    ]

    struct ToolDefinition: Encodable {
        var name: String
        var description: String
        var inputSchema: [String: AnyCodableJSON]
    }

    // MARK: - Schema builders

    private static func objectSchema(
        properties: [String: [String: AnyCodableJSON]],
        required: [String]
    ) -> [String: AnyCodableJSON] {
        var schema: [String: AnyCodableJSON] = [
            "type": .string("object"),
            "properties": .object(properties.mapValues { .object($0) }),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return schema
    }

    private static func stringSchema(description: String) -> [String: AnyCodableJSON] {
        ["type": .string("string"), "description": .string(description)]
    }

    private static func booleanSchema(description: String) -> [String: AnyCodableJSON] {
        ["type": .string("boolean"), "description": .string(description)]
    }

    private static func integerSchema(description: String) -> [String: AnyCodableJSON] {
        ["type": .string("integer"), "description": .string(description)]
    }

    private static func arrayOfStringsSchema(description: String) -> [String: AnyCodableJSON] {
        [
            "type": .string("array"),
            "description": .string(description),
            "items": .object(["type": .string("string")]),
        ]
    }

    /// Clamp an offset argument to >= 0.
    static func clampedOffset(_ raw: Int?) -> Int { max(raw ?? 0, 0) }

    /// Clamp a limit argument into 1…maxLimit.
    static func clampedLimit(_ raw: Int?) -> Int {
        let n = raw ?? defaultLimit
        return min(max(n, 1), maxLimit)
    }
}

/// Minimal JSON value for encoding heterogeneous tool schemas without Foundation JSONSerialization in the hot path.
enum AnyCodableJSON: Encodable, Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([AnyCodableJSON])
    case object([String: AnyCodableJSON])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .bool(let b): try container.encode(b)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}
