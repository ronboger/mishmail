import Foundation

/// Model lists for the Ask Mish provider → model submenu. Pure.
///
/// A provider's stored model list can be enormous (OpenRouter serves several
/// hundred ids), and a menu that long is unusable. Oversized lists are cut to
/// the well-known model families and capped; the provider's default model and
/// the current selection always stay visible. The full list remains available
/// in Settings → AI.
enum AskMishModelMenu {

    /// Longest model list shown under one provider before curation kicks in.
    static let maxModelsPerProvider = 24

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
        let total = list.count
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
        // The default and the active selection must stay reachable even when
        // curation would drop them.
        for pin in [selected ?? "", provider.defaultModel].filter({ !$0.isEmpty })
        where !list.contains(pin) {
            list.insert(pin, at: 0)
        }
        // The provider's default leads the list — it is what a click on the
        // provider row itself selects.
        if let index = list.firstIndex(of: provider.defaultModel), index > 0 {
            list.remove(at: index)
            list.insert(provider.defaultModel, at: 0)
        }
        return ProviderModels(models: list, hiddenCount: max(0, total - list.count))
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

    /// SF Symbol for a provider row, keyed off the label/kind. Monochrome
    /// stand-ins — the app ships no brand assets.
    static func icon(for provider: LLMProviderConfig) -> String {
        if provider.kind == .ollama { return "desktopcomputer" }
        let label = provider.label.lowercased()
        if label.contains("claude") || label.contains("anthropic") { return "asterisk" }
        if label.contains("chatgpt") || label.contains("openai") { return "hexagon" }
        if label.contains("gemini") || label.contains("google") { return "diamond" }
        if label.contains("grok") || label.contains("xai") { return "circle.slash" }
        if label.contains("openrouter") { return "arrow.triangle.branch" }
        return "cpu"
    }
}
