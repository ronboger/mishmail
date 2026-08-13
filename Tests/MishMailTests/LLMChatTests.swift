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
}
