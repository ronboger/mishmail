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
}

extension Ollama.OllamaError: Equatable {
    public static func == (lhs: Ollama.OllamaError, rhs: Ollama.OllamaError) -> Bool {
        switch (lhs, rhs) {
        case (.unreachable, .unreachable),
             (.insecureEndpoint, .insecureEndpoint),
             (.remoteNotAllowed, .remoteNotAllowed):
            return true
        default:
            return false
        }
    }
}
