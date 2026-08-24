import Foundation

/// Model lists for the Ask Mish provider → model submenu. Pure.
///
/// A provider's stored model list can be enormous (OpenRouter serves several
/// hundred ids), and a menu that long is unusable. Oversized lists are cut to
/// current chat models; image, audio, dated snapshots, and retired
/// generations stay out of browse. The provider's preferred default and the
/// current selection always stay visible. The full list remains available
/// through search and in Settings → AI.
enum AskMishModelMenu {

    /// Longest model list shown under one provider before curation kicks in.
    /// Deliberately short — browsing is for the common picks; anything else
    /// is one search away, over the full list.
    static let maxModelsPerProvider = 10

    /// Family substrings kept when a list is oversized.
    static let preferredFamilies = [
        "gpt", "claude", "gemini", "grok", "llama",
        "deepseek", "mistral", "qwen", "kimi", "glm",
    ]

    struct ProviderModels: Equatable {
        /// Models to list, in menu order.
        var models: [String]
        /// How many stored models the curation dropped (0 = full list shown).
        var hiddenCount: Int
    }

    static func models(for provider: LLMProviderConfig,
                       selected: String? = nil) -> ProviderModels {
        var seen = Set<String>()
        var list = (provider.models ?? [])
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        if list.isEmpty, !provider.defaultModel.isEmpty {
            list = [provider.defaultModel]
        }
        let storedIDs = list
        // Known vendors: offer the shipped current ids even when /models is stale.
        if provider.kind != .ollama, let vendor = subscriptionVendor(of: provider) {
            for model in LLMProviderStore.subscriptionPreset(for: vendor).fallbackModels
            where seen.insert(model).inserted {
                list.append(model)
            }
        }
        let leading = preferredDefault(for: provider)
        // Pins beat curation: when the user chose models, browse shows only
        // those (plus the default/selection pins below).
        let pinned = (provider.pinnedModels ?? []).filter { !$0.isEmpty }
        if !pinned.isEmpty {
            var pinSeen = Set<String>()
            var pinList = pinned.filter { pinSeen.insert($0).inserted }
            for pin in [selected ?? "", leading].filter({ !$0.isEmpty })
            where !pinList.contains(pin) {
                pinList.insert(pin, at: 0)
            }
            if let index = pinList.firstIndex(of: leading), index > 0 {
                pinList.remove(at: index)
                pinList.insert(leading, at: 0)
            }
            return ProviderModels(models: pinList,
                                  hiddenCount: hiddenCount(stored: storedIDs, shown: pinList))
        }
        if provider.kind != .ollama {
            let relevant = list.filter { isBrowseWorthy($0) }
            if !relevant.isEmpty { list = relevant }
        }
        if let vendor = subscriptionVendor(of: provider) {
            list = orderedByFallback(list, vendor: vendor)
        }
        if list.count > maxModelsPerProvider {
            let curated = list.filter { id in
                let lowered = id.lowercased()
                return preferredFamilies.contains { lowered.contains($0) }
            }
            list = curated.isEmpty ? list : curated
            if list.count > maxModelsPerProvider {
                list = Array(list.prefix(maxModelsPerProvider))
            }
        }
        // The active selection must stay reachable even when curation would
        // drop it. A stale stored default does not — preferredDefault leads.
        if let selected, !selected.isEmpty, !list.contains(selected) {
            list.insert(selected, at: 0)
        }
        if !leading.isEmpty {
            if let index = list.firstIndex(of: leading) {
                if index > 0 {
                    list.remove(at: index)
                    list.insert(leading, at: 0)
                }
            } else {
                list.insert(leading, at: 0)
            }
        }
        return ProviderModels(models: list, hiddenCount: hiddenCount(stored: storedIDs, shown: list))
    }

    /// True when `model` belongs in a browse list: chat, current generation,
    /// not a modality-specific or dated snapshot id.
    static func isBrowseWorthy(_ model: String) -> Bool {
        let id = model.lowercased()
        let name = displayName(id)
        let drop = [
            "image", "vision", "video", "audio", "tts", "whisper",
            "embedding", "moderation", "imagine", "realtime", "voice",
            "non-reasoning", "non_reasoning",
        ]
        if drop.contains(where: { name.contains($0) }) { return false }
        if name.contains("-beta") || name.hasSuffix("-exp") { return false }
        if name.range(of: #"-\d{4}$"#, options: .regularExpression) != nil
            || name.range(of: #"-\d{8}$"#, options: .regularExpression) != nil {
            return false
        }
        if name.hasPrefix("grok-2") || name.hasPrefix("grok-3") { return false }
        // grok-4.2 is a stale listing; grok-4.20 is a different, current id.
        if name.hasPrefix("grok-4.2") && !name.hasPrefix("grok-4.20") { return false }
        if name.contains("code-fast") { return false }
        if name.hasPrefix("gemini-1.") || name.hasPrefix("gemini-2.") { return false }
        if name.hasPrefix("gemini-1-") || name.hasPrefix("gemini-2-") { return false }
        return true
    }

    /// Model a new chat should use: a user-chosen current default if it is
    /// still browse-worthy, otherwise the first shipped id for this vendor.
    static func preferredDefault(for provider: LLMProviderConfig) -> String {
        if provider.kind == .ollama { return provider.defaultModel }
        let available = Set((provider.models ?? []).filter { !$0.isEmpty })
        if !provider.defaultModel.isEmpty,
           isBrowseWorthy(provider.defaultModel),
           available.isEmpty || available.contains(provider.defaultModel) {
            return provider.defaultModel
        }
        if let vendor = subscriptionVendor(of: provider),
           let first = LLMProviderStore.subscriptionPreset(for: vendor).fallbackModels.first {
            return first
        }
        if let first = (provider.models ?? []).first(where: { isBrowseWorthy($0) }) {
            return first
        }
        return provider.defaultModel
    }

    /// Subscription vendor inferred from OAuth mode or a shipped host.
    static func subscriptionVendor(of provider: LLMProviderConfig) -> LLMOAuthVendor? {
        if case .oauth(let vendor) = provider.authMode { return vendor }
        guard let host = LLMRemotePolicy.host(of: provider.baseURL) else { return nil }
        switch host {
        case "api.anthropic.com": return .claude
        case "api.openai.com": return .chatGPT
        case "generativelanguage.googleapis.com": return .gemini
        case "api.x.ai": return .grok
        case "openrouter.ai": return .openRouter
        default: return nil
        }
    }

    private static func hiddenCount(stored: [String], shown: [String]) -> Int {
        let visible = Set(shown)
        return stored.filter { !visible.contains($0) }.count
    }

    private static func orderedByFallback(_ list: [String],
                                          vendor: LLMOAuthVendor) -> [String] {
        let fallback = LLMProviderStore.subscriptionPreset(for: vendor).fallbackModels
        var seen = Set<String>()
        var ordered: [String] = []
        for model in fallback where list.contains(model) && seen.insert(model).inserted {
            ordered.append(model)
        }
        for model in list where seen.insert(model).inserted {
            ordered.append(model)
        }
        return ordered
    }

    // MARK: - Search

    struct SearchHit: Equatable, Identifiable {
        var providerID: UUID
        var providerLabel: String
        var model: String
        var id: String { "\(providerID.uuidString)/\(model)" }
    }

    /// Case-insensitive substring search over every provider's FULL stored
    /// model list (curation does not apply — search is how a hidden model is
    /// reached). Providers keep their order; models keep list order.
    static func search(providers: [LLMProviderConfig],
                       query: String, limit: Int = 30) -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for provider in providers {
            var models = provider.models ?? []
            if models.isEmpty, !provider.defaultModel.isEmpty {
                models = [provider.defaultModel]
            }
            for model in models
            where model.lowercased().contains(needle)
                || provider.label.lowercased().contains(needle) {
                hits.append(SearchHit(providerID: provider.id,
                                      providerLabel: provider.label, model: model))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    /// Asset-catalog name of the provider's brand mark (monochrome template
    /// SVGs vendored from LobeHub's MIT icon set), or nil when the provider
    /// has no mark — the UI then falls back to the `fallbackIcon` SF Symbol.
    static func brandAsset(for provider: LLMProviderConfig) -> String? {
        if provider.kind == .ollama { return "ProviderOllama" }
        if let vendor = subscriptionVendor(of: provider) {
            return brandAsset(forVendor: vendor)
        }
        let label = provider.label.lowercased()
        if label.contains("claude") || label.contains("anthropic") { return "ProviderClaude" }
        if label.contains("chatgpt") || label.contains("openai") { return "ProviderOpenAI" }
        if label.contains("gemini") || label.contains("google") { return "ProviderGemini" }
        if label.contains("grok") || label.contains("xai") { return "ProviderGrok" }
        if label.contains("openrouter") { return "ProviderOpenRouter" }
        return nil
    }

    static func brandAsset(forVendor vendor: LLMOAuthVendor) -> String {
        switch vendor {
        case .claude: return "ProviderClaude"
        case .chatGPT: return "ProviderOpenAI"
        case .gemini: return "ProviderGemini"
        case .grok: return "ProviderGrok"
        case .openRouter: return "ProviderOpenRouter"
        }
    }

    /// SF Symbol for providers without a vendored brand mark.
    static let fallbackIcon = "cpu"

    /// Short display title for a routed model id: the part after the vendor
    /// prefix ("nvidia/nemotron-3-super" → "nemotron-3-super"). Ids without a
    /// "/" pass through.
    static func displayName(_ model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }
}
