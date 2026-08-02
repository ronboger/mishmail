import Foundation

/// Connect-command snippets for wiring external agents to the in-app MCP
/// server. Pure so the exact command strings are unit-testable.
enum MCPConnectSnippets {
    enum Client: String, CaseIterable, Identifiable {
        case claudeCode = "Claude Code"
        case codex = "Codex CLI"
        case geminiCLI = "Gemini CLI"
        case generic = "Other (mcp-remote)"

        var id: String { rawValue }
    }

    static func url(port: UInt16) -> String {
        "http://127.0.0.1:\(port)/mcp"
    }

    /// The shell command (or config) to register the server with `client`.
    static func snippet(for client: Client, port: UInt16, token: String) -> String {
        let url = url(port: port)
        let auth = "Authorization: Bearer \(token)"
        switch client {
        case .claudeCode:
            return "claude mcp add --transport http mishmail \(url) --header \"\(auth)\""
        case .codex:
            // Codex's MCP client is stdio-first; mcp-remote bridges to HTTP.
            return "codex mcp add mishmail -- npx -y mcp-remote \(url) --header \"\(auth)\""
        case .geminiCLI:
            return "gemini mcp add --transport http mishmail \(url) --header \"\(auth)\""
        case .generic:
            // Any stdio-only MCP client: run this as the server command.
            return "npx -y mcp-remote \(url) --header \"\(auth)\""
        }
    }
}
