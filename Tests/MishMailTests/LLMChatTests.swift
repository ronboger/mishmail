import XCTest

final class LLMChatTests: XCTestCase {
    func testProviderConfigRoundTripsThroughJSON() throws {
        let config = LLMProviderConfig(
            id: UUID(), kind: .anthropic, label: "Claude",
            baseURL: "https://api.anthropic.com", defaultModel: "claude-sonnet-5",
            authMode: .oauth(.claude))
        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(LLMProviderConfig.self, from: data)
        XCTAssertEqual(back, config)

        let openRouter = LLMProviderConfig(
            id: UUID(), kind: .openAICompatible, label: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1", defaultModel: "openai/gpt-4o",
            authMode: .oauth(.openRouter))
        let orData = try JSONEncoder().encode(openRouter)
        XCTAssertEqual(try JSONDecoder().decode(LLMProviderConfig.self, from: orData), openRouter)
    }

    func testEndpointValidationAllowsLoopbackHTTP() throws {
        try LLMEndpoint.validate(URL(string: "http://127.0.0.1:11434/api/chat")!)
        try LLMEndpoint.validate(URL(string: "http://localhost:11434")!)
    }

    func testEndpointValidationRejectsRemoteHTTP() {
        XCTAssertThrowsError(try LLMEndpoint.validate(URL(string: "http://api.x.ai/v1")!))
    }

    func testEndpointValidationAllowsRemoteHTTPS() throws {
        try LLMEndpoint.validate(URL(string: "https://api.x.ai/v1")!)
    }

    func testRemotePolicyKnownHostsAndOffDevice() {
        XCTAssertTrue(LLMRemotePolicy.isKnownHost("api.x.ai"))
        XCTAssertTrue(LLMRemotePolicy.isKnownHost("openrouter.ai"))
        XCTAssertTrue(LLMRemotePolicy.isKnownHost("api.anthropic.com"))
        XCTAssertFalse(LLMRemotePolicy.isKnownHost("evil.example"))
        XCTAssertEqual(LLMRemotePolicy.host(of: "https://proxy.example/v1"), "proxy.example")

        let local = LLMProviderConfig(
            id: UUID(), kind: .ollama, label: "Ollama",
            baseURL: "http://127.0.0.1:11434", defaultModel: "llama",
            authMode: .apiKey)
        let grok = LLMProviderConfig(
            id: UUID(), kind: .openAICompatible, label: "Grok",
            baseURL: "https://api.x.ai/v1", defaultModel: "grok-4",
            authMode: .apiKey)
        let custom = LLMProviderConfig(
            id: UUID(), kind: .openAICompatible, label: "Proxy",
            baseURL: "https://llm.evil.example/v1", defaultModel: "x",
            authMode: .apiKey)
        XCTAssertFalse(LLMRemotePolicy.sendsMailOffDevice(local))
        XCTAssertTrue(LLMRemotePolicy.sendsMailOffDevice(grok))
        XCTAssertFalse(LLMRemotePolicy.requiresHostConsent(local))
        XCTAssertFalse(LLMRemotePolicy.requiresHostConsent(grok))
        XCTAssertTrue(LLMRemotePolicy.requiresHostConsent(custom))
        let broken = LLMProviderConfig(
            id: UUID(), kind: .openAICompatible, label: "Bad",
            baseURL: "not a url", defaultModel: "x", authMode: .apiKey)
        XCTAssertTrue(LLMRemotePolicy.sendsMailOffDevice(broken))
        XCTAssertTrue(LLMRemotePolicy.requiresHostConsent(broken))
        XCTAssertFalse(LLMRemotePolicy.isKnownHost("evil.api.openai.com"))
    }

    func testOriginIncludesSchemeAndDefaultPort() {
        XCTAssertEqual(LLMRemotePolicy.origin(of: "https://proxy.example/v1"),
                       "https://proxy.example:443")
        XCTAssertEqual(LLMRemotePolicy.origin(of: "https://proxy.example:8443/v1"),
                       "https://proxy.example:8443")
        XCTAssertEqual(LLMRemotePolicy.origin(of: "http://127.0.0.1:11434"),
                       "http://127.0.0.1:11434")
        XCTAssertNil(LLMRemotePolicy.origin(of: "not a url"))
    }

    func testPrivateLANHostsAndAutoSort() {
        XCTAssertTrue(LLMEndpoint.isPrivateLANHost("192.168.1.5"))
        XCTAssertTrue(LLMEndpoint.isPrivateLANHost("10.0.0.8"))
        XCTAssertTrue(LLMEndpoint.isPrivateLANHost("172.16.4.1"))
        XCTAssertTrue(LLMEndpoint.isPrivateLANHost("169.254.1.1"))
        XCTAssertTrue(LLMEndpoint.isPrivateLANHost("fd12::1"))
        XCTAssertFalse(LLMEndpoint.isPrivateLANHost("8.8.8.8"))
        XCTAssertFalse(LLMEndpoint.isPrivateLANHost("api.x.ai"))
        XCTAssertFalse(LLMEndpoint.isPrivateLANHost("fc.example.com"))

        let lan = LLMProviderConfig(
            id: UUID(), kind: .ollama, label: "LAN",
            baseURL: "https://192.168.1.5:11434", defaultModel: "llama",
            authMode: .apiKey)
        let grok = LLMProviderConfig(
            id: UUID(), kind: .openAICompatible, label: "Grok",
            baseURL: "https://api.x.ai/v1", defaultModel: "grok-4",
            authMode: .apiKey)
        XCTAssertTrue(LLMRemotePolicy.sendsMailOffDevice(lan))
        XCTAssertFalse(LLMRemotePolicy.blocksSilentAutoSort(lan))
        XCTAssertTrue(LLMRemotePolicy.blocksSilentAutoSort(grok))
    }

    func testFastVariantPicksFamilySibling() {
        XCTAssertEqual(
            LLMFastModel.fastVariant(of: "grok-4", available: ["grok-4", "grok-4-fast"]),
            "grok-4-fast")
        XCTAssertEqual(
            LLMFastModel.fastVariant(
                of: "claude-sonnet-5",
                available: ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"]),
            "claude-haiku-4-5")
        XCTAssertEqual(
            LLMFastModel.fastVariant(
                of: "gpt-5.4", available: ["gpt-5.4", "gpt-5.4-mini"]),
            "gpt-5.4-mini")
        XCTAssertEqual(
            LLMFastModel.fastVariant(
                of: "gemini-2.5-pro", available: ["gemini-2.5-pro", "gemini-2.5-flash"]),
            "gemini-2.5-flash")
        XCTAssertNil(LLMFastModel.fastVariant(of: "grok-4-fast", available: ["grok-4-fast"]))
        XCTAssertNil(LLMFastModel.fastVariant(of: "grok-4", available: ["grok-4"]))
    }

    // MARK: - Path derivation

    func testChatPathForBareBaseURLs() {
        XCTAssertEqual(LLMEndpoint.chatPath(kind: .openAICompatible, base: "https://api.x.ai"),
                       "https://api.x.ai/v1/chat/completions")
        XCTAssertEqual(LLMEndpoint.chatPath(kind: .anthropic, base: "https://api.anthropic.com"),
                       "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(LLMEndpoint.chatPath(kind: .ollama, base: "http://127.0.0.1:11434"),
                       "http://127.0.0.1:11434/api/chat")
    }

    func testChatPathDoesNotDoubleTheV1Segment() {
        XCTAssertEqual(LLMEndpoint.chatPath(kind: .openAICompatible, base: "https://api.x.ai/v1"),
                       "https://api.x.ai/v1/chat/completions")
        XCTAssertEqual(LLMEndpoint.chatPath(kind: .openAICompatible, base: "https://generativelanguage.googleapis.com/v1beta/openai"),
                       "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        XCTAssertEqual(LLMEndpoint.chatPath(kind: .anthropic, base: "https://api.anthropic.com/v1"),
                       "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(LLMEndpoint.chatPath(kind: .ollama, base: "http://127.0.0.1:11434/v1"),
                       "http://127.0.0.1:11434/v1/api/chat")
    }

    func testModelsPathForBareAndV1SuffixedBaseURLs() {
        XCTAssertEqual(LLMEndpoint.modelsPath(kind: .openAICompatible, base: "https://api.x.ai"),
                       "https://api.x.ai/v1/models")
        XCTAssertEqual(LLMEndpoint.modelsPath(kind: .openAICompatible, base: "https://api.x.ai/v1"),
                       "https://api.x.ai/v1/models")
        XCTAssertEqual(LLMEndpoint.modelsPath(kind: .openAICompatible, base: "https://generativelanguage.googleapis.com/v1beta/openai"),
                       "https://generativelanguage.googleapis.com/v1beta/openai/models")
        XCTAssertEqual(LLMEndpoint.modelsPath(kind: .anthropic, base: "https://api.anthropic.com"),
                       "https://api.anthropic.com/v1/models")
        XCTAssertEqual(LLMEndpoint.modelsPath(kind: .anthropic, base: "https://api.anthropic.com/v1"),
                       "https://api.anthropic.com/v1/models")
        XCTAssertEqual(LLMEndpoint.modelsPath(kind: .ollama, base: "http://127.0.0.1:11434"),
                       "http://127.0.0.1:11434/api/tags")
        XCTAssertEqual(LLMEndpoint.modelsPath(kind: .ollama, base: "http://127.0.0.1:11434/v1"),
                       "http://127.0.0.1:11434/v1/api/tags")
    }

    func testPathsTrimTrailingSlashesFromTheBaseURL() {
        XCTAssertEqual(LLMEndpoint.chatPath(kind: .openAICompatible, base: "https://api.x.ai/v1/"),
                       "https://api.x.ai/v1/chat/completions")
        XCTAssertEqual(LLMEndpoint.chatPath(kind: .ollama, base: "http://127.0.0.1:11434//"),
                       "http://127.0.0.1:11434/api/chat")
        XCTAssertEqual(LLMEndpoint.modelsPath(kind: .anthropic, base: "https://api.anthropic.com/"),
                       "https://api.anthropic.com/v1/models")
        XCTAssertEqual(LLMEndpoint.modelsPath(kind: .ollama, base: "http://127.0.0.1:11434/"),
                       "http://127.0.0.1:11434/api/tags")
    }

    // MARK: - Model-name extraction

    func testModelNamesReadsOllamaTagsPayload() {
        let object: Any = ["models": [["name": "qwen3:8b"], ["name": "llama3.2:3b"]]]
        XCTAssertEqual(LLMEndpoint.modelNames(fromJSONObject: object), ["llama3.2:3b", "qwen3:8b"])
    }

    func testModelNamesReadsOpenAIDataPayload() {
        let object: Any = ["data": [["id": "gpt-5.2"], ["id": "gpt-5.1-mini"]]]
        XCTAssertEqual(LLMEndpoint.modelNames(fromJSONObject: object), ["gpt-5.1-mini", "gpt-5.2"])
    }

    func testModelNamesStripsModelsPrefix() {
        let object: Any = ["models": [["name": "models/gemini-2.5-flash"], ["name": "models/gemini-2.5-pro"]]]
        XCTAssertEqual(LLMEndpoint.modelNames(fromJSONObject: object), ["gemini-2.5-flash", "gemini-2.5-pro"])
    }

    func testModelNamesPrefersModelsOverDataAndSkipsRowsWithoutNames() {
        let object: Any = ["models": [["name": "b"], ["size": 12], ["name": "a"]],
                           "data": [["id": "ignored"]]]
        XCTAssertEqual(LLMEndpoint.modelNames(fromJSONObject: object), ["a", "b"])
    }

    func testModelNamesReturnsEmptyForEmptyOrMalformedPayloads() {
        XCTAssertEqual(LLMEndpoint.modelNames(fromJSONObject: nil), [])
        XCTAssertEqual(LLMEndpoint.modelNames(fromJSONObject: [String: Any]()), [])
        XCTAssertEqual(LLMEndpoint.modelNames(fromJSONObject: ["models": "not-an-array"]), [])
        XCTAssertEqual(LLMEndpoint.modelNames(fromJSONObject: ["error": ["message": "nope"]]), [])
        XCTAssertEqual(LLMEndpoint.modelNames(fromJSONObject: [1, 2, 3]), [])
    }

    // MARK: - Done dedupe

    func testDoneDeduperPassesTokensThroughAndReportsNoDoneYet() {
        var deduper = LLMDoneDeduper()
        XCTAssertEqual(deduper.accept([.token("a"), .token("b")]), [.token("a"), .token("b")])
        XCTAssertFalse(deduper.sawDone)
    }

    func testDoneDeduperKeepsTheFirstDoneAndDropsLaterOnes() {
        var deduper = LLMDoneDeduper()
        let first = deduper.accept([.token("a"), .done(stopReason: "stop", usage: nil)])
        XCTAssertEqual(first, [.token("a"), .done(stopReason: "stop", usage: nil)])
        XCTAssertTrue(deduper.sawDone)
        XCTAssertEqual(deduper.accept([.done(stopReason: "tool_use", usage: nil)]), [])
        XCTAssertTrue(deduper.sawDone)
    }

    func testDoneDeduperDropsTheSecondDoneInsideOneBatch() {
        var deduper = LLMDoneDeduper()
        let events: [LLMEvent] = [.done(stopReason: "stop", usage: nil),
                                  .done(stopReason: "stop", usage: nil)]
        XCTAssertEqual(deduper.accept(events), [.done(stopReason: "stop", usage: nil)])
    }

    func testDoneDeduperStillForwardsToolCallsAfterDone() {
        var deduper = LLMDoneDeduper()
        _ = deduper.accept([.done(stopReason: "stop", usage: nil)])
        let call = LLMToolCall(id: "1", name: "search", argumentsJSON: "{}")
        XCTAssertEqual(deduper.accept([.toolCall(call)]), [.toolCall(call)])
    }
}
