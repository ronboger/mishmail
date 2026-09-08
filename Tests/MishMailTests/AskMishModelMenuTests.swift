import XCTest

final class AskMishModelMenuTests: XCTestCase {
    private func provider(models: [String]?, defaultModel: String = "gpt-5") -> LLMProviderConfig {
        LLMProviderConfig(
            id: UUID(), kind: .openAICompatible, label: "Test",
            baseURL: "https://example.com/v1", defaultModel: defaultModel,
            authMode: .apiKey, models: models)
    }

    func testSmallListPassesThroughDeduped() {
        let result = AskMishModelMenu.models(
            for: provider(models: ["gpt-5", "gpt-5-mini", "gpt-5", ""]))
        XCTAssertEqual(result.models, ["gpt-5", "gpt-5-mini"])
        XCTAssertEqual(result.hiddenCount, 0)
    }

    func testNilModelsFallsBackToDefaultModel() {
        let result = AskMishModelMenu.models(for: provider(models: nil))
        XCTAssertEqual(result.models, ["gpt-5"])
        XCTAssertEqual(result.hiddenCount, 0)
    }

    func testOversizedListKeepsKnownFamiliesAndCaps() {
        let noise = (0..<300).map { "vendor/odd-model-\($0)" }
        let known = ["openai/gpt-5", "anthropic/claude-sonnet-5", "google/gemini-3.7-flash"]
        let result = AskMishModelMenu.models(
            for: provider(models: noise + known, defaultModel: "openai/gpt-5"))
        XCTAssertTrue(result.models.contains("openai/gpt-5"))
        XCTAssertTrue(result.models.contains("anthropic/claude-sonnet-5"))
        XCTAssertTrue(result.models.contains("google/gemini-3.7-flash"))
        XCTAssertFalse(result.models.contains("vendor/odd-model-0"))
        XCTAssertLessThanOrEqual(result.models.count, AskMishModelMenu.maxModelsPerProvider + 2)
        XCTAssertEqual(result.hiddenCount, 300)
    }

    func testSelectionAndDefaultSurviveCuration() {
        let noise = (0..<100).map { "vendor/odd-model-\($0)" }
        let result = AskMishModelMenu.models(
            for: provider(models: noise, defaultModel: "vendor/odd-model-99"),
            selected: "vendor/odd-model-42")
        XCTAssertTrue(result.models.contains("vendor/odd-model-99"))
        XCTAssertTrue(result.models.contains("vendor/odd-model-42"))
    }

    func testDefaultModelLeadsTheList() {
        let result = AskMishModelMenu.models(
            for: provider(models: ["gpt-5-nano", "gpt-5-mini", "gpt-5"], defaultModel: "gpt-5"))
        XCTAssertEqual(result.models.first, "gpt-5")
    }

    func testPinnedModelsReplaceBrowseListAndKeepDefaultFirst() {
        var p = provider(models: (0..<50).map { "m-\($0)" } + ["gpt-5"], defaultModel: "gpt-5")
        p.pinnedModels = ["m-30", "m-7"]
        let result = AskMishModelMenu.models(for: p, selected: "m-2")
        XCTAssertEqual(result.models, ["gpt-5", "m-2", "m-30", "m-7"])
        XCTAssertEqual(result.hiddenCount, 51 - 4)
    }

    func testDisplayNameStripsVendorPrefix() {
        XCTAssertEqual(AskMishModelMenu.displayName("nvidia/nemotron-3-super"), "nemotron-3-super")
        XCTAssertEqual(AskMishModelMenu.displayName("gpt-5.6-luna"), "gpt-5.6-luna")
    }

    func testSearchFindsModelsCurationHid() {
        let noise = (0..<300).map { "vendor/odd-model-\($0)" }
        let p = provider(models: noise, defaultModel: "vendor/odd-model-0")
        let hits = AskMishModelMenu.search(providers: [p], query: "odd-model-250")
        XCTAssertEqual(hits.map(\.model), ["vendor/odd-model-250"])
    }

    func testSearchMatchesProviderLabelAndIsCaseInsensitive() {
        let p = provider(models: ["gpt-5", "gpt-5-mini"])
        XCTAssertEqual(AskMishModelMenu.search(providers: [p], query: "TEST").count, 2)
        XCTAssertEqual(AskMishModelMenu.search(providers: [p], query: "MINI").map(\.model),
                       ["gpt-5-mini"])
        XCTAssertTrue(AskMishModelMenu.search(providers: [p], query: "  ").isEmpty)
    }

    func testAllKnownFamiliesStillCapped() {
        let many = (0..<80).map { "gpt-variant-\($0)" }
        let result = AskMishModelMenu.models(for: provider(models: many, defaultModel: "gpt-variant-0"))
        XCTAssertLessThanOrEqual(result.models.count, AskMishModelMenu.maxModelsPerProvider)
        XCTAssertGreaterThan(result.hiddenCount, 0)
    }

    private func grok(models: [String], defaultModel: String) -> LLMProviderConfig {
        LLMProviderConfig(
            id: UUID(), kind: .openAICompatible, label: "Grok",
            baseURL: "https://api.x.ai/v1", defaultModel: defaultModel,
            authMode: .oauth(.grok), models: models)
    }

    private func gemini(models: [String], defaultModel: String,
                        label: String = "Studio") -> LLMProviderConfig {
        LLMProviderConfig(
            id: UUID(), kind: .openAICompatible, label: label,
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            defaultModel: defaultModel, authMode: .apiKey, models: models)
    }

    func testGrokBrowseHidesStaleAndModalityIds() {
        let catalog = [
            "grok-4.2", "grok-4.20", "grok-4.20-beta", "grok-4.1-fast", "grok-4",
            "grok-3", "grok-3-mini", "grok-2-1212", "grok-2-vision-1212",
            "grok-2-image-1212", "grok-code-fast-1", "grok-4-1-fast-non-reasoning",
        ]
        let result = AskMishModelMenu.models(
            for: grok(models: catalog, defaultModel: "grok-4.2"))
        XCTAssertFalse(result.models.contains("grok-4.2"))
        XCTAssertFalse(result.models.contains("grok-4.20-beta"))
        XCTAssertFalse(result.models.contains("grok-3"))
        XCTAssertFalse(result.models.contains("grok-2-1212"))
        XCTAssertFalse(result.models.contains("grok-2-image-1212"))
        XCTAssertFalse(result.models.contains("grok-code-fast-1"))
        XCTAssertFalse(result.models.contains("grok-4-1-fast-non-reasoning"))
        XCTAssertTrue(result.models.contains("grok-4.6"))
        XCTAssertTrue(result.models.contains("grok-4.1-fast"))
        XCTAssertTrue(result.models.contains("grok-4.20"))
        XCTAssertEqual(result.models.first, "grok-4.6")
        XCTAssertGreaterThan(result.hiddenCount, 0)
    }

    func testGrok42IsNotThePreferredDefault() {
        let p = grok(models: ["grok-4.2", "grok-4.1-fast", "grok-4"],
                     defaultModel: "grok-4.2")
        XCTAssertEqual(AskMishModelMenu.preferredDefault(for: p), "grok-4.6")
        XCTAssertFalse(AskMishModelMenu.isBrowseWorthy("grok-4.2"))
        XCTAssertTrue(AskMishModelMenu.isBrowseWorthy("grok-4.20"))
        XCTAssertTrue(AskMishModelMenu.isBrowseWorthy("grok-4.1-fast"))
        XCTAssertFalse(AskMishModelMenu.isBrowseWorthy("claude-sonnet-4-20250514"))
    }

    func testGeminiBrowseHidesRetiredGenerations() {
        let catalog = [
            "gemini-1.5-pro", "gemini-1.5-flash", "gemini-2.0-flash",
            "gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-image",
            "gemini-3.7-flash", "gemini-3.5-flash",
        ]
        let result = AskMishModelMenu.models(
            for: gemini(models: catalog, defaultModel: "gemini-1.5-pro"))
        XCTAssertFalse(result.models.contains { $0.hasPrefix("gemini-1.") })
        XCTAssertFalse(result.models.contains { $0.hasPrefix("gemini-2.") })
        XCTAssertFalse(result.models.contains("gemini-2.5-flash-image"))
        XCTAssertTrue(result.models.contains("gemini-3.7-flash"))
        XCTAssertTrue(result.models.contains("gemini-3.5-flash"))
        XCTAssertEqual(result.models.first, "gemini-3.7-flash")
    }

    func testSearchStillFindsHiddenGrokModels() {
        let p = grok(models: ["grok-4.2", "grok-4.6"], defaultModel: "grok-4.2")
        XCTAssertEqual(AskMishModelMenu.search(providers: [p], query: "4.2").map(\.model),
                       ["grok-4.2"])
    }

    func testBrandAssetMatchesGeminiHostWithoutGoogleInTheLabel() {
        let p = gemini(models: ["gemini-3.7-flash"], defaultModel: "gemini-3.7-flash",
                       label: "Studio")
        XCTAssertEqual(AskMishModelMenu.brandAsset(for: p), "ProviderGemini")
        XCTAssertEqual(AskMishModelMenu.subscriptionVendor(of: p), .gemini)
    }

    func testBrandAssetMatchesGrokOAuthEvenWithACustomLabel() {
        var p = grok(models: ["grok-4.6"], defaultModel: "grok-4.6")
        p.label = "xAI"
        XCTAssertEqual(AskMishModelMenu.brandAsset(for: p), "ProviderGrok")
    }

    private func claude(models: [String], defaultModel: String) -> LLMProviderConfig {
        LLMProviderConfig(
            id: UUID(), kind: .anthropic, label: "Claude",
            baseURL: "https://api.anthropic.com", defaultModel: defaultModel,
            authMode: .oauth(.claude), models: models)
    }

    func testCurrentFloorHidesHaiku35AndClaude3() {
        let catalog = [
            "claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5",
            "claude-3-5-haiku", "claude-3-5-sonnet", "claude-3-7-sonnet",
        ]
        let result = AskMishModelMenu.models(
            for: claude(models: catalog, defaultModel: "claude-opus-5"),
            floor: .current)
        XCTAssertTrue(result.models.contains("claude-opus-5"))
        XCTAssertTrue(result.models.contains("claude-sonnet-5"))
        XCTAssertTrue(result.models.contains("claude-haiku-4-5"))
        XCTAssertFalse(result.models.contains("claude-3-5-haiku"))
        XCTAssertFalse(result.models.contains("claude-3-5-sonnet"))
        XCTAssertFalse(result.models.contains("claude-3-7-sonnet"))
        XCTAssertEqual(result.models.first, "claude-opus-5")
        XCTAssertGreaterThan(result.hiddenCount, 0)
    }

    func testAllFloorShowsOlderClaude() {
        let catalog = ["claude-opus-5", "claude-3-5-haiku"]
        let result = AskMishModelMenu.models(
            for: claude(models: catalog, defaultModel: "claude-opus-5"),
            floor: nil)
        XCTAssertTrue(result.models.contains("claude-3-5-haiku"))
        XCTAssertEqual(result.models.first, "claude-opus-5")
    }

    func testFrontierFloorKeepsOpusOnly() {
        let catalog = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"]
        let result = AskMishModelMenu.models(
            for: claude(models: catalog, defaultModel: "claude-opus-5"),
            floor: .frontier)
        XCTAssertEqual(result.models, ["claude-opus-5"])
    }

    func testSelectedOlderModelStaysVisible() {
        let catalog = ["claude-opus-5", "claude-3-5-haiku"]
        let result = AskMishModelMenu.models(
            for: claude(models: catalog, defaultModel: "claude-opus-5"),
            selected: "claude-3-5-haiku",
            floor: .current)
        XCTAssertTrue(result.models.contains("claude-3-5-haiku"))
    }

    func testGroupedOrdersFrontierFirst() {
        let groups = AskMishModelMenu.grouped([
            "claude-haiku-4-5", "claude-opus-5", "claude-sonnet-5", "claude-3-5-haiku",
        ])
        XCTAssertEqual(groups.map(\.intelligence), [.frontier, .strong, .current, .older])
        XCTAssertEqual(groups[0].models, ["claude-opus-5"])
        XCTAssertEqual(groups[1].models, ["claude-sonnet-5"])
        XCTAssertEqual(groups[2].models, ["claude-haiku-4-5"])
        XCTAssertEqual(groups[3].models, ["claude-3-5-haiku"])
    }

    func testFloorPersistence() {
        let defaults = UserDefaults(suiteName: "AskMishModelMenu.floor.\(UUID().uuidString)")!
        XCTAssertEqual(AskMishModelMenu.storedFloor(from: defaults), .current)
        AskMishModelMenu.setStoredFloor(.frontier, to: defaults)
        XCTAssertEqual(AskMishModelMenu.storedFloor(from: defaults), .frontier)
        AskMishModelMenu.setStoredFloor(nil, to: defaults)
        XCTAssertNil(AskMishModelMenu.storedFloor(from: defaults))
        AskMishModelMenu.setStoredFloor(.current, to: defaults)
        XCTAssertEqual(AskMishModelMenu.storedFloor(from: defaults), .current)
    }

    func testSearchStillFindsOlderClaude() {
        let p = claude(models: ["claude-opus-5", "claude-3-5-haiku"],
                       defaultModel: "claude-opus-5")
        XCTAssertEqual(AskMishModelMenu.search(providers: [p], query: "haiku").map(\.model),
                       ["claude-3-5-haiku"])
    }
}
