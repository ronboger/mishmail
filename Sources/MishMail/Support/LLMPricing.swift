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
        model.lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// Shipped defaults, matched by longest key prefix. Update freely;
    /// user overrides win.
    static func shippedDefaults() -> [String: LLMPrice] {
        [
            "claude-fable-5": LLMPrice(inputPerMTok: 20, outputPerMTok: 100),
            "claude-opus-5": LLMPrice(inputPerMTok: 12, outputPerMTok: 60),
            "claude-sonnet-5": LLMPrice(inputPerMTok: 3, outputPerMTok: 15),
            "claude-haiku-4-5": LLMPrice(inputPerMTok: 1, outputPerMTok: 5),
            "gpt-5": LLMPrice(inputPerMTok: 1.25, outputPerMTok: 10),
            "grok-4": LLMPrice(inputPerMTok: 3, outputPerMTok: 15),
            "gemini-2.5-pro": LLMPrice(inputPerMTok: 1.25, outputPerMTok: 10),
        ]
    }

    static func price(model: String, overrides: [String: LLMPrice]) -> LLMPrice? {
        let key = matchKey(model: model)
        if let exact = overrides[key] ?? overrides.first(where: { key.hasPrefix($0.key) })?.value {
            return exact
        }
        let defaults = shippedDefaults()
        if let exact = defaults[key] { return exact }
        return defaults
            .filter { key.hasPrefix($0.key) }
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
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}
