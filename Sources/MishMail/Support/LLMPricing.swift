import Foundation

/// USD price per million tokens for one model.
struct LLMPrice: Codable, Equatable, Sendable {
    var inputPerMTok: Double
    var outputPerMTok: Double
}

/// Local, editable price table. Tokens are the source of truth; prices
/// drift, so dollar figures are estimates. Subscription (OAuth) providers
/// show token counts only.
enum LLMPricing {
    static let defaultsKey = "llm.prices"

    static func matchKey(model: String) -> String {
        model.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Shipped defaults, matched by longest key prefix. Update freely;
    /// user overrides win.
    static func shippedDefaults() -> [String: LLMPrice] {
        [
            "claude-fable-5": LLMPrice(inputPerMTok: 10, outputPerMTok: 50),
            "claude-opus-5": LLMPrice(inputPerMTok: 5, outputPerMTok: 25),
            "claude-opus-4": LLMPrice(inputPerMTok: 5, outputPerMTok: 25),
            "claude-sonnet-5": LLMPrice(inputPerMTok: 3, outputPerMTok: 15),
            "claude-sonnet-4": LLMPrice(inputPerMTok: 3, outputPerMTok: 15),
            "claude-3-7-sonnet": LLMPrice(inputPerMTok: 3, outputPerMTok: 15),
            "claude-3-5-sonnet": LLMPrice(inputPerMTok: 3, outputPerMTok: 15),
            "claude-3-5-haiku": LLMPrice(inputPerMTok: 0.8, outputPerMTok: 4),
            "claude-haiku-4-5": LLMPrice(inputPerMTok: 1, outputPerMTok: 5),
            "gpt-5": LLMPrice(inputPerMTok: 1.25, outputPerMTok: 10),
            "gpt-5-mini": LLMPrice(inputPerMTok: 0.25, outputPerMTok: 2),
            "gpt-5-nano": LLMPrice(inputPerMTok: 0.05, outputPerMTok: 0.4),
            "grok-4.6": LLMPrice(inputPerMTok: 2, outputPerMTok: 6),
            "grok-4.1-fast": LLMPrice(inputPerMTok: 0.2, outputPerMTok: 0.5),
            "grok-4.20": LLMPrice(inputPerMTok: 1.25, outputPerMTok: 2.5),
            "grok-4": LLMPrice(inputPerMTok: 3, outputPerMTok: 15),
            "grok-4-fast": LLMPrice(inputPerMTok: 0.2, outputPerMTok: 0.5),
            "gemini-3.7-pro": LLMPrice(inputPerMTok: 1.25, outputPerMTok: 10),
            "gemini-3.7-flash": LLMPrice(inputPerMTok: 0.15, outputPerMTok: 0.60),
            "gemini-3.1-pro": LLMPrice(inputPerMTok: 1.25, outputPerMTok: 10),
            "gemini-3.1-flash-lite": LLMPrice(inputPerMTok: 0.075, outputPerMTok: 0.30),
            "gemini-3.6-flash": LLMPrice(inputPerMTok: 0.15, outputPerMTok: 0.60),
            "gemini-2.5-pro": LLMPrice(inputPerMTok: 1.25, outputPerMTok: 10),
            "gemini-2.5-flash": LLMPrice(inputPerMTok: 0.15, outputPerMTok: 0.60),
            "gemini-2.0-flash": LLMPrice(inputPerMTok: 0.10, outputPerMTok: 0.40),
            "gemini-2.0-flash-lite": LLMPrice(inputPerMTok: 0.075, outputPerMTok: 0.30),
            "gemini-1.5-pro": LLMPrice(inputPerMTok: 1.25, outputPerMTok: 5.0),
            "gemini-1.5-flash": LLMPrice(inputPerMTok: 0.075, outputPerMTok: 0.30),
        ]
    }

    static func price(model: String, overrides: [String: LLMPrice]) -> LLMPrice? {
        let key = matchKey(model: model)
        if let hit = longestPrefixMatch(key: key, in: overrides) { return hit }
        return longestPrefixMatch(key: key, in: shippedDefaults())
    }

    /// Exact key wins; otherwise the longest non-empty prefix key wins.
    private static func longestPrefixMatch(key: String,
                                          in table: [String: LLMPrice]) -> LLMPrice? {
        if let exact = table[key] { return exact }
        return table
            .filter { key.hasPrefix($0.key) && !$0.key.isEmpty }
            .max { $0.key.count < $1.key.count }?
            .value
    }

    static func loadOverrides(from defaults: UserDefaults = .standard) -> [String: LLMPrice] {
        guard let data = defaults.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode([String: LLMPrice].self, from: data)
        else { return [:] }
        return stored
    }

    static func saveOverrides(_ overrides: [String: LLMPrice],
                              to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(overrides) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    static func cost(usage: LLMUsage, price: LLMPrice) -> Double {
        Double(usage.promptTokens) / 1_000_000 * price.inputPerMTok
            + Double(usage.completionTokens) / 1_000_000 * price.outputPerMTok
    }

    /// "1.2k in · 300 out · $0.0081" for keyed providers with a known price;
    /// "1.2k in · 300 out" for OAuth or unknown-price models; nil without usage.
    static func costLabel(usage: LLMUsage?, config: LLMProviderConfig,
                          model: String, overrides: [String: LLMPrice]) -> String? {
        guard let usage else { return nil }
        let tokens = "\(compactCount(usage.promptTokens)) in · \(compactCount(usage.completionTokens)) out"
        if case .oauth = config.authMode { return tokens }
        guard let price = price(model: model, overrides: overrides) else { return tokens }
        return "\(tokens) · \(formatUSD(cost(usage: usage, price: price)))"
    }

    static func formatUSD(_ value: Double) -> String {
        value < 0.01 ? String(format: "$%.4f", value) : String(format: "$%.2f", value)
    }

    static func compactCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
}
