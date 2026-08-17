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
    case grok
    case gemini
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
    /// Model list pulled from the provider after connect (nil = never fetched).
    /// Optional so rows stored before this field existed still decode.
    var models: [String]? = nil
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

    /// Drops trailing slashes so path joining never produces "//".
    static func trimmedBase(_ raw: String) -> String {
        var base = raw
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    /// Chat/completions URL string for one provider kind. A base that already
    /// ends in "/v1" or "/openai" is not given an extra "/v1".
    static func chatPath(kind: LLMProviderKind, base rawBase: String) -> String {
        let base = trimmedBase(rawBase)
        switch kind {
        case .openAICompatible:
            if base.hasSuffix("/chat/completions") { return base }
            if base.hasSuffix("/v1") || base.hasSuffix("/openai") {
                return "\(base)/chat/completions"
            }
            return "\(base)/v1/chat/completions"
        case .anthropic:
            if base.hasSuffix("/messages") { return base }
            return base.hasSuffix("/v1") ? "\(base)/messages" : "\(base)/v1/messages"
        case .ollama:
            return "\(base)/api/chat"
        }
    }

    /// Model-listing URL string for one provider kind.
    static func modelsPath(kind: LLMProviderKind, base rawBase: String) -> String {
        let base = trimmedBase(rawBase)
        switch kind {
        case .ollama:
            return "\(base)/api/tags"
        case .anthropic:
            if base.hasSuffix("/models") { return base }
            return base.hasSuffix("/v1") ? "\(base)/models" : "\(base)/v1/models"
        case .openAICompatible:
            if base.hasSuffix("/models") { return base }
            if base.hasSuffix("/v1") || base.hasSuffix("/openai") {
                return "\(base)/models"
            }
            return "\(base)/v1/models"
        }
    }

    /// Model names out of a decoded listing payload: Ollama `/api/tags` uses
    /// `models[].name`; OpenAI and Anthropic use `data[].id`. Anything else
    /// gives an empty list, so a malformed body is not an error.
    static func modelNames(fromJSONObject object: Any?) -> [String] {
        guard let root = object as? [String: Any] else { return [] }
        if let models = root["models"] as? [[String: Any]] {
            return models.compactMap { dict -> String? in
                guard let name = dict["name"] as? String else { return nil }
                return name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
            }.sorted()
        }
        if let rows = root["data"] as? [[String: Any]] {
            return rows.compactMap { dict -> String? in
                guard let id = dict["id"] as? String else { return nil }
                return id.hasPrefix("models/") ? String(id.dropFirst("models/".count)) : id
            }.sorted()
        }
        return []
    }
}

/// Keeps a stream to exactly one `.done`: every batch of parsed events goes
/// through `accept`, which drops any `.done` after the first and records that
/// one was seen. Callers use `sawDone` to decide whether an end-of-body flush
/// is still needed.
struct LLMDoneDeduper {
    private(set) var sawDone = false

    mutating func accept(_ events: [LLMEvent]) -> [LLMEvent] {
        var out: [LLMEvent] = []
        for event in events {
            if case .done = event {
                if sawDone { continue }
                sawDone = true
            }
            out.append(event)
        }
        return out
    }
}
