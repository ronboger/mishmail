import XCTest

final class OllamaEndpointTests: XCTestCase {
    private var savedURL: String!
    private var savedAllow: Bool!

    override func setUp() {
        super.setUp()
        savedURL = Ollama.baseURL
        savedAllow = Ollama.allowRemoteEndpoint
    }

    override func tearDown() {
        Ollama.baseURL = savedURL
        Ollama.allowRemoteEndpoint = savedAllow
        super.tearDown()
    }

    func testLoopbackAlwaysAllowed() throws {
        Ollama.baseURL = "http://127.0.0.1:11434"
        Ollama.allowRemoteEndpoint = false
        let url = URL(string: "\(Ollama.baseURL)/api/generate")!
        XCTAssertNoThrow(try Ollama.validateEndpoint(url))
    }

    func testRemoteHTTPRejected() {
        Ollama.baseURL = "http://evil.example:11434"
        Ollama.allowRemoteEndpoint = true
        let url = URL(string: "\(Ollama.baseURL)/api/generate")!
        XCTAssertThrowsError(try Ollama.validateEndpoint(url)) { error in
            XCTAssertEqual(error as? Ollama.OllamaError, .insecureEndpoint)
        }
    }

    func testRemoteHTTPSRequiresOptIn() {
        Ollama.baseURL = "https://gpu.example"
        Ollama.allowRemoteEndpoint = false
        let url = URL(string: "\(Ollama.baseURL)/api/generate")!
        XCTAssertThrowsError(try Ollama.validateEndpoint(url)) { error in
            XCTAssertEqual(error as? Ollama.OllamaError, .remoteNotAllowed)
        }

        Ollama.allowRemoteEndpoint = true
        XCTAssertNoThrow(try Ollama.validateEndpoint(url))
    }

    func testEnabledModelsFiltersDisabled() {
        let saved = Ollama.disabledModels
        defer { Ollama.disabledModels = saved }
        Ollama.disabledModels = ["llama3.2"]
        XCTAssertEqual(Ollama.enabledModels(installed: ["llama3.2", "qwen3"]), ["qwen3"])
        Ollama.disabledModels = []
        XCTAssertEqual(Ollama.enabledModels(installed: ["llama3.2"]), ["llama3.2"])
    }

    func testChat404BecomesModelMissingError() {
        let error = Ollama.chatFailure(status: 404, model: "llama3.2")
        XCTAssertEqual(error, .modelNotInstalled("llama3.2"))
        XCTAssertTrue(error?.errorDescription?.contains("llama3.2") == true)
        XCTAssertTrue(error?.errorDescription?.contains("ollama pull") == true)
    }

    func testNon404StatusesAreNotTranslated() {
        XCTAssertNil(Ollama.chatFailure(status: 500, model: "llama3.2"))
        XCTAssertNil(Ollama.chatFailure(status: 400, model: "llama3.2"))
    }
}

extension Ollama.OllamaError: Equatable {
    public static func == (lhs: Ollama.OllamaError, rhs: Ollama.OllamaError) -> Bool {
        switch (lhs, rhs) {
        case (.insecureEndpoint, .insecureEndpoint),
             (.remoteNotAllowed, .remoteNotAllowed):
            return true
        case (.modelNotInstalled(let lhsModel), .modelNotInstalled(let rhsModel)):
            return lhsModel == rhsModel
        default:
            return false
        }
    }
}
