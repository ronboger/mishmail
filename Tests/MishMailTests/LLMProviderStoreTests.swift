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
        XCTAssertFalse(preset.fallbackModels.isEmpty)

        let geminiPreset = LLMProviderStore.subscriptionPreset(for: .gemini)
        XCTAssertEqual(geminiPreset.kind, .openAICompatible)
        XCTAssertEqual(geminiPreset.baseURL, "https://generativelanguage.googleapis.com/v1beta/openai")
        XCTAssertTrue(geminiPreset.fallbackModels.contains("gemini-3.7-flash"))
        XCTAssertTrue(geminiPreset.fallbackModels.contains("gemini-2.5-pro"))

        let connected = LLMProviderConfig(
            id: UUID(), kind: .anthropic, label: "Claude",
            baseURL: "https://api.anthropic.com", defaultModel: "claude-opus-5",
            authMode: .oauth(.claude), models: ["claude-opus-5"])
        XCTAssertEqual(
            LLMProviderStore.subscriptionProvider(for: .claude, in: [connected])?.id,
            connected.id)
        XCTAssertNil(LLMProviderStore.subscriptionProvider(for: .grok, in: [connected]))
        XCTAssertNil(LLMProviderStore.subscriptionProvider(for: .gemini, in: [connected]))
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
