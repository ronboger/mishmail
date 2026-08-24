import XCTest

final class LLMProviderStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "LLMProviderStoreTests")!
        defaults.removePersistentDomain(forName: "LLMProviderStoreTests")
    }

    func testLoadWithNothingStoredReturnsBuiltInOllamaRow() {
        let providers = LLMProviderStore.load(from: defaults)
        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers[0].kind, .ollama)
        XCTAssertEqual(providers[0].id, LLMProviderStore.builtInOllamaID)
    }

    func testSaveThenLoadRoundTripsAndKeepsOllamaRow() {
        let grok = LLMProviderConfig(
            id: UUID(), kind: .openAICompatible, label: "Grok",
            baseURL: "https://api.x.ai/v1", defaultModel: "grok-4-0709",
            authMode: .apiKey)
        LLMProviderStore.save([grok], to: defaults)
        let loaded = LLMProviderStore.load(from: defaults)
        XCTAssertTrue(loaded.contains(grok))
        XCTAssertTrue(loaded.contains { $0.kind == .ollama })
    }

    func testLoadKeepsValidRowsWhenOneStoredRowIsGarbage() {
        let good = LLMProviderConfig(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            kind: .openAICompatible, label: "Grok",
            baseURL: "https://api.x.ai/v1", defaultModel: "grok-4-0709",
            authMode: .apiKey)
        let goodJSON = String(data: try! JSONEncoder().encode(good), encoding: .utf8)!
        let json = "[\(goodJSON),{\"id\":\"66666666-7777-8888-9999-AAAAAAAAAAAA\"}]"
        defaults.set(Data(json.utf8), forKey: LLMProviderStore.defaultsKey)

        let loaded = LLMProviderStore.load(from: defaults)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertTrue(loaded.contains(good))
        XCTAssertTrue(loaded.contains { $0.id == LLMProviderStore.builtInOllamaID })
    }

    func testKeychainKeyNamesDeriveFromID() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        XCTAssertEqual(LLMProviderStore.keychainKey(for: id),
                       "llm.key.AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(LLMProviderStore.oauthKeychainKey(for: id),
                       "llm.oauth.AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(LLMProviderStore.hostConsentKey(for: id),
                       "llm.hostConsent.AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
    }

    func testHostConsentMatchesExactHostAndFailsClosedOnChange() {
        let id = UUID()
        let custom = LLMProviderConfig(
            id: id, kind: .openAICompatible, label: "Proxy",
            baseURL: "https://llm.evil.example/v1", defaultModel: "x",
            authMode: .apiKey)
        XCTAssertFalse(LLMProviderStore.hasHostConsent(for: custom, from: defaults))
        LLMProviderStore.setConsentedHost("llm.evil.example", for: id, to: defaults)
        XCTAssertTrue(LLMProviderStore.hasHostConsent(for: custom, from: defaults))
        var moved = custom
        moved.baseURL = "https://other.evil.example/v1"
        XCTAssertFalse(LLMProviderStore.hasHostConsent(for: moved, from: defaults))
        let grok = LLMProviderConfig(
            id: UUID(), kind: .openAICompatible, label: "Grok",
            baseURL: "https://api.x.ai/v1", defaultModel: "grok-4.6",
            authMode: .apiKey)
        XCTAssertTrue(LLMProviderStore.hasHostConsent(for: grok, from: defaults))
        let broken = LLMProviderConfig(
            id: UUID(), kind: .openAICompatible, label: "Bad",
            baseURL: "not a url", defaultModel: "x", authMode: .apiKey)
        XCTAssertFalse(LLMProviderStore.hasHostConsent(for: broken, from: defaults))
    }

    func testTaskAssignmentDefaultsToBuiltInOllamaAndRoundTrips() {
        let unset = LLMProviderStore.assignment(for: .drafts, from: defaults)
        XCTAssertEqual(unset.providerID, LLMProviderStore.builtInOllamaID)
        let custom = LLMTaskAssignment(providerID: UUID(), model: "claude-sonnet-5")
        LLMProviderStore.setAssignment(custom, for: .drafts, to: defaults)
        XCTAssertEqual(LLMProviderStore.assignment(for: .drafts, from: defaults), custom)
    }

    func testSubscriptionPresetAndLookup() {
        let preset = LLMProviderStore.subscriptionPreset(for: .grok)
        XCTAssertEqual(preset.kind, .openAICompatible)
        XCTAssertEqual(preset.baseURL, "https://api.x.ai/v1")
        XCTAssertEqual(preset.fallbackModels.first, "grok-4.6")
        XCTAssertTrue(preset.fallbackModels.contains("grok-4.1-fast"))
        XCTAssertFalse(preset.fallbackModels.contains("grok-4.2"))

        let geminiPreset = LLMProviderStore.subscriptionPreset(for: .gemini)
        XCTAssertEqual(geminiPreset.kind, .openAICompatible)
        XCTAssertEqual(geminiPreset.baseURL, "https://generativelanguage.googleapis.com/v1beta/openai")
        XCTAssertEqual(geminiPreset.fallbackModels.first, "gemini-3.7-flash")
        XCTAssertTrue(geminiPreset.fallbackModels.contains("gemini-3.5-flash"))
        XCTAssertFalse(geminiPreset.fallbackModels.contains { $0.hasPrefix("gemini-1.") || $0.hasPrefix("gemini-2.") })

        let connected = LLMProviderConfig(
            id: UUID(), kind: .anthropic, label: "Claude",
            baseURL: "https://api.anthropic.com", defaultModel: "claude-opus-5",
            authMode: .oauth(.claude), models: ["claude-opus-5"])
        XCTAssertEqual(
            LLMProviderStore.subscriptionProvider(for: .claude, in: [connected])?.id,
            connected.id)
        XCTAssertNil(LLMProviderStore.subscriptionProvider(for: .grok, in: [connected]))
        XCTAssertNil(LLMProviderStore.subscriptionProvider(for: .gemini, in: [connected]))

        let openRouterPreset = LLMProviderStore.subscriptionPreset(for: .openRouter)
        XCTAssertEqual(openRouterPreset.kind, .openAICompatible)
        XCTAssertEqual(openRouterPreset.baseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(openRouterPreset.label, "OpenRouter")
        XCTAssertTrue(openRouterPreset.fallbackModels.contains("openai/gpt-4o"))
        let openRouter = LLMProviderConfig(
            id: UUID(), kind: .openAICompatible, label: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1", defaultModel: "openai/gpt-4o",
            authMode: .oauth(.openRouter))
        XCTAssertEqual(
            LLMProviderStore.subscriptionProvider(for: .openRouter, in: [openRouter])?.id,
            openRouter.id)
        XCTAssertNil(LLMProviderStore.subscriptionProvider(for: .openRouter, in: [connected]))
    }

    func testProviderRowWithoutModelsFieldStillDecodes() throws {
        let json = """
        [{"id":"11111111-2222-3333-4444-555555555555","kind":"anthropic",        "label":"Claude","baseURL":"https://api.anthropic.com",        "defaultModel":"claude-opus-5","authMode":{"apiKey":{}}}]
        """
        let rows = LLMProviderStore.decodeProviders(from: Data(json.utf8))
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].models)
    }
}
