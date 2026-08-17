import XCTest

final class LLMPricingTests: XCTestCase {
    func testExactAndPrefixPriceLookup() {
        let overrides = ["grok-4-0709": LLMPrice(inputPerMTok: 3, outputPerMTok: 15)]
        XCTAssertEqual(LLMPricing.price(model: "Grok-4-0709", overrides: overrides)?.inputPerMTok, 3)
        // Shipped defaults match by longest prefix: "claude-sonnet-5-20260101" hits "claude-sonnet-5".
        XCTAssertNotNil(LLMPricing.price(model: "claude-sonnet-5-20260101", overrides: [:]))
        XCTAssertNil(LLMPricing.price(model: "totally-unknown-model", overrides: [:]))
    }

    func testOverlappingOverrideKeysPickLongestPrefix() {
        // Two override keys both prefix-match the model id. The longest must win,
        // deterministically, no matter how the dictionary happens to iterate.
        let overrides = [
            "grok-4": LLMPrice(inputPerMTok: 3, outputPerMTok: 15),
            "grok-4-1": LLMPrice(inputPerMTok: 0.2, outputPerMTok: 0.5),
        ]
        for _ in 0..<50 {
            XCTAssertEqual(LLMPricing.price(model: "grok-4-1212", overrides: overrides),
                           LLMPrice(inputPerMTok: 0.2, outputPerMTok: 0.5))
        }
    }

    func testShippedCheapVariantsBeatShorterPrefix() {
        let mini = LLMPricing.price(model: "gpt-5-mini-2026", overrides: [:])
        XCTAssertEqual(mini, LLMPrice(inputPerMTok: 0.25, outputPerMTok: 2))
        XCTAssertEqual(LLMPricing.price(model: "gpt-5-nano", overrides: [:]),
                       LLMPrice(inputPerMTok: 0.05, outputPerMTok: 0.4))
        XCTAssertEqual(LLMPricing.price(model: "grok-4-fast-reasoning", overrides: [:]),
                       LLMPrice(inputPerMTok: 0.2, outputPerMTok: 0.5))
        XCTAssertEqual(LLMPricing.price(model: "gemini-3.7-flash", overrides: [:]),
                       LLMPrice(inputPerMTok: 0.15, outputPerMTok: 0.60))
        XCTAssertEqual(LLMPricing.price(model: "gemini-3.7-pro", overrides: [:]),
                       LLMPrice(inputPerMTok: 1.25, outputPerMTok: 10))
        XCTAssertEqual(LLMPricing.price(model: "gemini-2.5-flash", overrides: [:]),
                       LLMPrice(inputPerMTok: 0.15, outputPerMTok: 0.60))
        XCTAssertEqual(LLMPricing.price(model: "gemini-2.5-pro", overrides: [:]),
                       LLMPrice(inputPerMTok: 1.25, outputPerMTok: 10))
        // The plain rows still resolve for ids that are not a cheap variant.
        XCTAssertEqual(LLMPricing.price(model: "gpt-5-2026-01-01", overrides: [:]),
                       LLMPrice(inputPerMTok: 1.25, outputPerMTok: 10))
    }

    func testEmptyOverrideKeyIsIgnored() {
        let overrides = ["": LLMPrice(inputPerMTok: 999, outputPerMTok: 999)]
        XCTAssertEqual(LLMPricing.price(model: "claude-sonnet-5", overrides: overrides),
                       LLMPrice(inputPerMTok: 3, outputPerMTok: 15))
        XCTAssertNil(LLMPricing.price(model: "totally-unknown-model", overrides: overrides))
    }

    func testMatchKeyTrimsNewlines() {
        XCTAssertEqual(LLMPricing.matchKey(model: " GPT-5-Mini\n"), "gpt-5-mini")
        XCTAssertEqual(LLMPricing.price(model: "gpt-5-mini\n", overrides: [:]),
                       LLMPrice(inputPerMTok: 0.25, outputPerMTok: 2))
    }

    func testCompactCountUnits() {
        XCTAssertEqual(LLMPricing.compactCount(999), "999")
        XCTAssertEqual(LLMPricing.compactCount(1200), "1.2k")
        XCTAssertEqual(LLMPricing.compactCount(2_000_000), "2.0M")
        XCTAssertEqual(LLMPricing.compactCount(1_500_000), "1.5M")
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
        // Keyed but the model has no shipped or override price: tokens only, no dollars.
        let unpricedLabel = LLMPricing.costLabel(usage: usage, config: keyed,
                                                 model: "totally-unknown-model",
                                                 overrides: [:])!
        XCTAssertEqual(unpricedLabel, "1.2k in · 300 out")
        XCTAssertFalse(unpricedLabel.contains("$"))
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
