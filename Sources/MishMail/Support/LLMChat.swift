import Foundation

/// Provider-neutral chat types shared by all LLM wire codecs and the client.
/// Pure data — no networking here.

enum LLMProviderKind: String, Codable, CaseIterable, Sendable {
    case anthropic
    case openAICompatible
    case ollama
}

enum LLMOAuthVendor: String, Codable, Sendable {
    case claude
    case chatGPT
}

enum LLMAuthMode: Codable, Equatable, Sendable {
    case apiKey
    case oauth(LLMOAuthVendor)
}

struct LLMProviderConfig: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var kind: LLMProviderKind
    var label: String
    var baseURL: String
    var defaultModel: String
    var authMode: LLMAuthMode
}

enum LLMRole: String, Codable, Sendable { case system, user, assistant, tool }

struct LLMToolCall: Codable, Equatable, Sendable {
    var id: String
    var name: String
    /// Raw JSON object string of the tool arguments.
    var argumentsJSON: String
}

struct LLMToolResult: Codable, Equatable, Sendable {
    var callID: String
    /// Raw JSON (or plain text) content returned by the tool.
    var content: String
    var isError: Bool
}

struct LLMMessage: Codable, Equatable, Sendable {
    var role: LLMRole
    var text: String
    var toolCalls: [LLMToolCall] = []
    var toolResults: [LLMToolResult] = []

    init(role: LLMRole, text: String,
         toolCalls: [LLMToolCall] = [], toolResults: [LLMToolResult] = []) {
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.toolResults = toolResults
    }
}

struct LLMToolSpec: Equatable, Sendable {
    var name: String
    var description: String
    /// Raw JSON Schema object string for the tool input.
    var inputSchemaJSON: String
}

struct LLMUsage: Codable, Equatable, Sendable {
    var promptTokens: Int
    var completionTokens: Int
}

enum LLMEvent: Equatable, Sendable {
    case token(String)
    case toolCall(LLMToolCall)
    case done(stopReason: String, usage: LLMUsage?)
}

/// Endpoint rule shared by every provider: loopback is always allowed;
/// anything remote must be HTTPS. Mail content never travels cleartext.
enum LLMEndpoint {
    enum ValidationError: LocalizedError, Equatable {
        case insecure(String)
        var errorDescription: String? {
            switch self {
            case .insecure(let url):
                return "Endpoint \(url) is neither local nor HTTPS. Use a local URL or an https:// URL."
            }
        }
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    static func validate(_ url: URL) throws {
        if isLoopback(url) { return }
        if url.scheme?.lowercased() != "https" {
            throw ValidationError.insecure(url.absoluteString)
        }
    }
}
