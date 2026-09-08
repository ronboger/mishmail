import XCTest

final class LLMModelRankTests: XCTestCase {
    func testClaudeRanks() {
        XCTAssertEqual(LLMModelIntelligence.of("claude-fable-5-1"), .frontier)
        XCTAssertEqual(LLMModelIntelligence.of("claude-opus-5"), .frontier)
        XCTAssertEqual(LLMModelIntelligence.of("claude-opus-4-6"), .frontier)
        XCTAssertEqual(LLMModelIntelligence.of("claude-sonnet-5"), .strong)
        XCTAssertEqual(LLMModelIntelligence.of("claude-sonnet-4-6"), .strong)
        XCTAssertEqual(LLMModelIntelligence.of("claude-haiku-4-5"), .current)
        XCTAssertEqual(LLMModelIntelligence.of("claude-3-5-haiku"), .older)
        XCTAssertEqual(LLMModelIntelligence.of("anthropic/claude-3.5-haiku"), .older)
        XCTAssertEqual(LLMModelIntelligence.of("claude-3-5-sonnet"), .older)
        XCTAssertEqual(LLMModelIntelligence.of("claude-3-7-sonnet"), .older)
    }

    func testGPTAndOSeriesRanks() {
        XCTAssertEqual(LLMModelIntelligence.of("gpt-5.6-sol"), .frontier)
        XCTAssertEqual(LLMModelIntelligence.of("gpt-5.4"), .frontier)
        XCTAssertEqual(LLMModelIntelligence.of("gpt-5"), .strong)
        XCTAssertEqual(LLMModelIntelligence.of("gpt-5-mini"), .current)
        XCTAssertEqual(LLMModelIntelligence.of("gpt-4o"), .older)
        XCTAssertEqual(LLMModelIntelligence.of("gpt-4.1"), .older)
        XCTAssertEqual(LLMModelIntelligence.of("openai/gpt-4o"), .older)
        XCTAssertEqual(LLMModelIntelligence.of("o3-pro"), .frontier)
        XCTAssertEqual(LLMModelIntelligence.of("o3"), .strong)
        XCTAssertEqual(LLMModelIntelligence.of("o4-mini"), .strong)
        XCTAssertEqual(LLMModelIntelligence.of("o3-mini"), .current)
        XCTAssertEqual(LLMModelIntelligence.of("o1"), .older)
    }

    func testGeminiAndGrokRanks() {
        XCTAssertEqual(LLMModelIntelligence.of("gemini-3.1-pro"), .frontier)
        XCTAssertEqual(LLMModelIntelligence.of("gemini-3.7-flash"), .strong)
        XCTAssertEqual(LLMModelIntelligence.of("gemini-3.5-flash-lite"), .current)
        XCTAssertEqual(LLMModelIntelligence.of("gemini-2.5-pro"), .older)
        XCTAssertEqual(LLMModelIntelligence.of("grok-4.6"), .frontier)
        XCTAssertEqual(LLMModelIntelligence.of("grok-4.20"), .strong)
        XCTAssertEqual(LLMModelIntelligence.of("grok-4.1-fast"), .current)
        XCTAssertEqual(LLMModelIntelligence.of("grok-3"), .older)
        XCTAssertEqual(LLMModelIntelligence.of("grok-2-1212"), .older)
    }

    func testUnknownIdsCountAsCurrent() {
        XCTAssertEqual(LLMModelIntelligence.of("vendor/odd-model-1"), .current)
    }

    func testHostedThinkingSupport() {
        XCTAssertTrue(LLMHostedThinking.supports("claude-sonnet-5"))
        XCTAssertTrue(LLMHostedThinking.supports("claude-opus-4-6"))
        XCTAssertTrue(LLMHostedThinking.supports("claude-3-7-sonnet"))
        XCTAssertFalse(LLMHostedThinking.supports("claude-3-5-haiku"))
        XCTAssertFalse(LLMHostedThinking.supports("claude-3-5-sonnet"))
        XCTAssertTrue(LLMHostedThinking.supports("gpt-5"))
        XCTAssertTrue(LLMHostedThinking.supports("o3"))
        XCTAssertFalse(LLMHostedThinking.supports("gpt-4o"))
        XCTAssertTrue(LLMHostedThinking.supports("gemini-3.7-flash"))
        XCTAssertFalse(LLMHostedThinking.supports("grok-4.6"))
        XCTAssertTrue(LLMHostedThinking.supports("grok-3-mini"))
        XCTAssertFalse(LLMHostedThinking.supports("grok-2-1212"))
        XCTAssertTrue(LLMHostedThinking.supports("anthropic/claude-sonnet-5"))
        XCTAssertFalse(LLMHostedThinking.supports("llama3.2"))
    }

    func testAdaptiveThinkingOn46And5() {
        XCTAssertTrue(LLMHostedThinking.usesAdaptive("claude-opus-4-6"))
        XCTAssertTrue(LLMHostedThinking.usesAdaptive("claude-sonnet-5"))
        XCTAssertFalse(LLMHostedThinking.usesAdaptive("claude-sonnet-4-5"))
        XCTAssertFalse(LLMHostedThinking.usesAdaptive("claude-3-7-sonnet"))
        XCTAssertEqual(LLMHostedThinking.anthropicEffort("xhigh", model: "claude-opus-4-6"), "max")
        XCTAssertEqual(LLMHostedThinking.anthropicEffort("xhigh", model: "claude-opus-5"), "xhigh")
        XCTAssertEqual(LLMHostedThinking.anthropicEffort("high", model: "claude-opus-4-6"), "high")
        XCTAssertFalse(LLMHostedThinking.acceptsDisabled("claude-fable-5-1"))
        XCTAssertTrue(LLMHostedThinking.acceptsDisabled("claude-sonnet-5"))
        XCTAssertFalse(LLMHostedThinking.acceptsDisabled("claude-sonnet-4-5"))
        XCTAssertEqual(LLMHostedThinking.openAIEffort("medium", model: "grok-3-mini"), "high")
    }
}
