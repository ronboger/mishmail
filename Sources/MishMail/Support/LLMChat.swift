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
    case openRouter
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
    /// Models the user pinned for quick picking. When non-empty, browse UIs
    /// show ONLY these (plus the default); the full list stays searchable.
    /// Optional so rows stored before this field existed still decode.
    var pinnedModels: [String]? = nil
}

enum LLMRole: String, Codable, Sendable { case system, user, assistant, tool }

/// Whether a local model reasons before it answers, and how hard — Ollama's
/// `think` field.
///
/// `off` is safe on every model: Ollama accepts `think: false` even for a model
/// with no thinking capability. A *level* is not — `think: "low"` on such a
/// model fails the whole request with "does not support thinking" — so callers
/// must check `capabilities` before sending one.
enum LLMThinking: Equatable, Sendable {
    case modelDefault
    case off
    case level(String)

    /// Stored form, for UserDefaults and pickers.
    var rawValue: String {
        switch self {
        case .modelDefault: return "default"
        case .off: return "off"
        case .level(let level): return level
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "off": self = .off
        case "low", "medium", "high": self = .level(rawValue)
        default: self = .modelDefault
        }
    }

    /// The JSON value for `think`, or nil when the field should be left out.
    var wireValue: Any? {
        switch self {
        case .modelDefault: return nil
        case .off: return false
        case .level(let level): return level
        }
    }
}

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
    /// A fragment of the model's thinking trace (DeepSeek `reasoning_content`,
    /// OpenRouter `reasoning`, Ollama `thinking`, Anthropic thinking deltas).
    case reasoning(String)
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

/// Whether a provider sends mail text off this Mac, and whether a custom
/// host still needs an explicit consent (preset hosts are expected).
enum LLMRemotePolicy {
    /// Hosts we ship as presets. Mail to these is expected; a typed-in
    /// host needs a confirm because it receives mail content.
    static let knownHosts: Set<String> = [
        "api.anthropic.com",
        "api.openai.com",
        "generativelanguage.googleapis.com",
        "openrouter.ai",
        "api.x.ai",
        "api.groq.com",
    ]

    static func host(of baseURL: String) -> String? {
        let trimmed = LLMEndpoint.trimmedBase(baseURL)
        guard let url = URL(string: trimmed),
              let host = url.host, !host.isEmpty else { return nil }
        return host.lowercased()
    }

    static func isKnownHost(_ host: String) -> Bool {
        knownHosts.contains(host.lowercased())
    }

    /// True when this provider's endpoint is not loopback. Fail closed on
    /// a URL we cannot parse: better to skip auto-sort than leak mail.
    static func sendsMailOffDevice(_ config: LLMProviderConfig) -> Bool {
        let trimmed = LLMEndpoint.trimmedBase(config.baseURL)
        guard let url = URL(string: trimmed) else { return true }
        return !LLMEndpoint.isLoopback(url)
    }

    /// Custom HTTPS hosts (not a shipped preset) need a stored consent
    /// matching this exact host before we send mail there.
    static func requiresHostConsent(_ config: LLMProviderConfig) -> Bool {
        guard sendsMailOffDevice(config) else { return false }
        guard let host = host(of: config.baseURL) else { return true }
        return !isKnownHost(host)
    }
}

extension LLMEndpoint {
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
