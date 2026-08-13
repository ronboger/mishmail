import Foundation

/// Which app feature a model call belongs to. Each task can use a
/// different provider/model (cheap local triage, hosted drafting).
enum LLMTask: String, CaseIterable, Sendable {
    case drafts, summaries, triage, askMish
}

struct LLMTaskAssignment: Codable, Equatable, Sendable {
    var providerID: UUID
    var model: String
}

/// Persists provider metadata in UserDefaults (never secrets — those live
/// in the Keychain under names derived here) and per-task model choices.
enum LLMProviderStore {
    static let defaultsKey = "llm.providers"
    /// Stable id for the built-in Ollama row so task assignments and
    /// defaults survive re-creation.
    static let builtInOllamaID = UUID(uuidString: "00000000-0000-0000-0000-00000000011A")!

    static func builtInOllama() -> LLMProviderConfig {
        LLMProviderConfig(id: builtInOllamaID, kind: .ollama, label: "Ollama (local)",
                          baseURL: Ollama.baseURL, defaultModel: Ollama.model,
                          authMode: .apiKey)
    }

    /// The built-in Ollama row is always present and always reflects the
    /// live `Ollama` settings; stored rows never shadow it.
    static func load(from defaults: UserDefaults = .standard) -> [LLMProviderConfig] {
        var providers: [LLMProviderConfig] = []
        if let data = defaults.data(forKey: defaultsKey) {
            providers = decodeProviders(from: data).filter { $0.id != builtInOllamaID }
        }
        return providers + [builtInOllama()]
    }

    /// Decodes the stored array. One bad row must not discard the others,
    /// which would orphan Keychain secrets, so fall back to a per-row pass.
    static func decodeProviders(from data: Data) -> [LLMProviderConfig] {
        let decoder = JSONDecoder()
        if let stored = try? decoder.decode([LLMProviderConfig].self, from: data) {
            return stored
        }
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return []
        }
        return rows.compactMap { row in
            guard let rowData = try? JSONSerialization.data(withJSONObject: row) else {
                return nil
            }
            return try? decoder.decode(LLMProviderConfig.self, from: rowData)
        }
    }

    static func save(_ providers: [LLMProviderConfig],
                     to defaults: UserDefaults = .standard) {
        let stored = providers.filter { $0.id != builtInOllamaID }
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    struct SubscriptionPreset {
        let label: String
        let kind: LLMProviderKind
        let baseURL: String
        /// Shown if the provider's /models endpoint rejects subscription
        /// tokens; sign-in must not fail just because listing did.
        let fallbackModels: [String]
    }

    /// One-click subscription sign-in targets (Settings → AI → Subscriptions).
    static func subscriptionPreset(for vendor: LLMOAuthVendor) -> SubscriptionPreset {
        switch vendor {
        case .claude:
            return SubscriptionPreset(
                label: "Claude", kind: .anthropic,
                baseURL: "https://api.anthropic.com",
                fallbackModels: ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"])
        case .chatGPT:
            return SubscriptionPreset(
                label: "ChatGPT", kind: .openAICompatible,
                baseURL: "https://api.openai.com/v1",
                fallbackModels: ["gpt-5", "gpt-5-mini"])
        case .grok:
            return SubscriptionPreset(
                label: "Grok", kind: .openAICompatible,
                baseURL: "https://api.x.ai/v1",
                fallbackModels: ["grok-4", "grok-4-fast"])
        }
    }

    /// The stored provider row for one subscription vendor, if connected.
    static func subscriptionProvider(for vendor: LLMOAuthVendor,
                                     in providers: [LLMProviderConfig]) -> LLMProviderConfig? {
        providers.first { $0.authMode == .oauth(vendor) }
    }

    static func keychainKey(for id: UUID) -> String { "llm.key.\(id.uuidString)" }
    static func oauthKeychainKey(for id: UUID) -> String { "llm.oauth.\(id.uuidString)" }

    static func assignmentKey(for task: LLMTask) -> String { "llm.task.\(task.rawValue)" }

    static func assignment(for task: LLMTask,
                           from defaults: UserDefaults = .standard) -> LLMTaskAssignment {
        if let data = defaults.data(forKey: assignmentKey(for: task)),
           let stored = try? JSONDecoder().decode(LLMTaskAssignment.self, from: data) {
            return stored
        }
        return LLMTaskAssignment(providerID: builtInOllamaID, model: Ollama.model)
    }

    static func setAssignment(_ assignment: LLMTaskAssignment, for task: LLMTask,
                              to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(assignment) {
            defaults.set(data, forKey: assignmentKey(for: task))
        }
    }
}
