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
}
