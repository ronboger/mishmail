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
        return ProviderModels(models: list, hiddenCount: max(0, total - list.count))
    }
}
