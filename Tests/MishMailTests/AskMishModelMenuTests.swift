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
        let known = ["openai/gpt-5", "anthropic/claude-sonnet-5", "google/gemini-2.5-pro"]
        let result = AskMishModelMenu.models(
            for: provider(models: noise + known, defaultModel: "openai/gpt-5"))
        XCTAssertTrue(result.models.contains("openai/gpt-5"))
        XCTAssertTrue(result.models.contains("anthropic/claude-sonnet-5"))
        XCTAssertTrue(result.models.contains("google/gemini-2.5-pro"))
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

    func testAllKnownFamiliesStillCapped() {
        let many = (0..<80).map { "gpt-variant-\($0)" }
        let result = AskMishModelMenu.models(for: provider(models: many, defaultModel: "gpt-variant-0"))
        XCTAssertLessThanOrEqual(result.models.count, AskMishModelMenu.maxModelsPerProvider)
        XCTAssertGreaterThan(result.hiddenCount, 0)
    }
}
