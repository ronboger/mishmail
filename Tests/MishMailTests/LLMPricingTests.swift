import XCTest

final class LLMPricingTests: XCTestCase {
    func testExactAndPrefixPriceLookup() {
        let overrides = ["grok-4-0709": LLMPrice(inputPerMTok: 3, outputPerMTok: 15)]
        XCTAssertEqual(LLMPricing.price(model: "Grok-4-0709", overrides: overrides)?.inputPerMTok, 3)
        // Shipped defaults match by longest prefix: "claude-sonnet-5-20260101" hits "claude-sonnet-5".
        XCTAssertNotNil(LLMPricing.price(model: "claude-sonnet-5-20260101", overrides: [:]))
        XCTAssertNil(LLMPricing.price(model: "totally-unknown-model", overrides: [:]))
    }

    func testCostMath() {
        let price = LLMPrice(inputPerMTok: 3, outputPerMTok: 15)
        let usage = LLMUsage(promptTokens: 1_000_000, completionTokens: 2_000_000)
        XCTAssertEqual(LLMPricing.cost(usage: usage, price: price), 33.0, accuracy: 0.0001)
    }

    func testCostLabelRules() {
        let oauth = LLMProviderConfig(id: UUID(), kind: .anthropic, label: "Claude",
                                      baseURL: "https://api.anthropic.com",
                                      defaultModel: "claude-sonnet-5",
                                      authMode: .oauth(.claude))
        let keyed = LLMProviderConfig(id: UUID(), kind: .openAICompatible, label: "Grok",
                                      baseURL: "https://api.x.ai/v1",
                                      defaultModel: "grok-4-0709", authMode: .apiKey)
        let usage = LLMUsage(promptTokens: 1200, completionTokens: 300)
        // OAuth subscription: tokens only, no dollars.
        let oauthLabel = LLMPricing.costLabel(usage: usage, config: oauth,
                                              model: "claude-sonnet-5", overrides: [:])!
        XCTAssertTrue(oauthLabel.contains("1.2k"))
        XCTAssertFalse(oauthLabel.contains("$"))
        // Keyed with a known price: dollars shown.
        let keyedLabel = LLMPricing.costLabel(
            usage: usage, config: keyed, model: "grok-4-0709",
            overrides: ["grok-4-0709": LLMPrice(inputPerMTok: 3, outputPerMTok: 15)])!
        XCTAssertTrue(keyedLabel.contains("$"))
        // No usage → no label.
        XCTAssertNil(LLMPricing.costLabel(usage: nil, config: keyed,
                                          model: "grok-4-0709", overrides: [:]))
    }

    func testOverridesRoundTrip() {
        let defaults = UserDefaults(suiteName: "LLMPricingTests")!
        defaults.removePersistentDomain(forName: "LLMPricingTests")
        let overrides = ["m1": LLMPrice(inputPerMTok: 1, outputPerMTok: 2)]
        LLMPricing.saveOverrides(overrides, to: defaults)
        XCTAssertEqual(LLMPricing.loadOverrides(from: defaults), overrides)
    }
}
