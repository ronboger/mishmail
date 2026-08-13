import AppKit
import Foundation

enum LLMClientError: LocalizedError {
    case missingCredential
    case http(Int)
    case keychainUnavailable

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "No API key or sign-in for this provider. Add one in Settings → AI."
        case .http(let code):
            return "The model provider returned HTTP \(code)."
        case .keychainUnavailable:
            return "Keychain is unavailable. Unlock your Mac and try again."
        }
    }
}

/// One streaming client for every provider kind. Builds requests with the
/// pure wire codecs, streams SSE/NDJSON lines through the matching
/// StreamState, refreshes OAuth tokens on 401 (single retry).
actor LLMClient {
    static let shared = LLMClient()

    func stream(messages: [LLMMessage], tools: [LLMToolSpec],
                config: LLMProviderConfig, model: String) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(messages: messages, tools: tools, config: config,
                                       model: model, allowRefresh: true) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(messages: [LLMMessage], tools: [LLMToolSpec],
                     config: LLMProviderConfig, model: String, allowRefresh: Bool,
                     yield: @Sendable (LLMEvent) -> Void) async throws {
        // Refresh up front when the stored token already expired, so the common
        // case costs one request instead of a 401 plus a retry. A failure here
        // is not fatal: the stale token still gets its 401 retry below.
        if allowRefresh, case .oauth(let vendor) = config.authMode,
           storedTokensAreExpired(providerID: config.id) {
            try? await refreshTokens(vendor: vendor, providerID: config.id)
        }
        let request = try await buildRequest(messages: messages, tools: tools,
                                            config: config, model: model)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, allowRefresh, case .oauth(let vendor) = config.authMode {
            try await refreshTokens(vendor: vendor, providerID: config.id)
            return try await run(messages: messages, tools: tools, config: config,
                                 model: model, allowRefresh: false, yield: yield)
        }
        guard (200..<300).contains(status) else { throw LLMClientError.http(status) }

        switch config.kind {
        case .openAICompatible:
            var state = OpenAIWire.StreamState()
            // A server that closes without "data: [DONE]" still has to flush
            // its buffered tool calls, so feed the terminator ourselves.
            try await pump(bytes: bytes,
                           consume: { state.consume(line: $0) },
                           finalFlush: { state.consume(line: "data: [DONE]") },
                           yield: yield)
        case .anthropic:
            var state = AnthropicWire.StreamState()
            try await pump(bytes: bytes,
                           consume: { state.consume(line: $0) },
                           finalFlush: { [.done(stopReason: "stop", usage: nil)] },
                           yield: yield)
        case .ollama:
            var state = OllamaChatWire.StreamState()
            try await pump(bytes: bytes,
                           consume: { state.consume(line: $0) },
                           finalFlush: { [.done(stopReason: "stop", usage: nil)] },
                           yield: yield)
        }
    }

    /// Feeds every line of the response to `consume`, forwards the events, and
    /// guarantees exactly one `.done`: `finalFlush` runs when the body ends
    /// without a terminator, and any extra `.done` is dropped. Callers can
    /// therefore always wait for `.done` and never hang.
    private func pump(bytes: URLSession.AsyncBytes,
                      consume: (String) -> [LLMEvent],
                      finalFlush: () -> [LLMEvent],
                      yield: @Sendable (LLMEvent) -> Void) async throws {
        var sawDone = false
        func emit(_ events: [LLMEvent]) {
            for event in events {
                if case .done = event {
                    if sawDone { continue }
                    sawDone = true
                }
                yield(event)
            }
        }
        for try await line in bytes.lines {
            emit(consume(line))
        }
        if !sawDone { emit(finalFlush()) }
        if !sawDone { emit([.done(stopReason: "stop", usage: nil)]) }
    }

    private func buildRequest(messages: [LLMMessage], tools: [LLMToolSpec],
                              config: LLMProviderConfig, model: String) async throws -> URLRequest {
        let base = Self.trimmedBase(config.baseURL)
        let path: String
        let body: Data
        switch config.kind {
        case .openAICompatible:
            path = base.hasSuffix("/v1") ? "\(base)/chat/completions" : "\(base)/v1/chat/completions"
            body = try OpenAIWire.requestBody(model: model, messages: messages, tools: tools)
        case .anthropic:
            path = "\(base)/v1/messages"
            body = try AnthropicWire.requestBody(model: model, messages: messages,
                                                 tools: tools, maxTokens: 8192)
        case .ollama:
            path = "\(base)/api/chat"
            body = try OllamaChatWire.requestBody(model: model, messages: messages, tools: tools)
        }
        guard let url = URL(string: path) else { throw LLMClientError.http(0) }
        try LLMEndpoint.validate(url)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        try applyAuth(to: &request, config: config)
        return request
    }

    private static func trimmedBase(_ raw: String) -> String {
        raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    private func applyAuth(to request: inout URLRequest, config: LLMProviderConfig) throws {
        if config.kind == .ollama { return } // local, keyless
        guard OAuthConfig.usesKeychain(environment: ProcessInfo.processInfo.environment) else {
            throw LLMClientError.missingCredential // fixture builds never touch Keychain
        }
        switch config.authMode {
        case .apiKey:
            guard case .value(let key) = Keychain.read(LLMProviderStore.keychainKey(for: config.id))
            else { throw LLMClientError.missingCredential }
            switch config.kind {
            case .anthropic:
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            default:
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        case .oauth:
            guard let tokens = storedTokens(providerID: config.id) else {
                throw LLMClientError.missingCredential
            }
            request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
            if config.kind == .anthropic {
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            }
        }
    }

    private func storedTokens(providerID: UUID) -> LLMOAuthTokens? {
        guard case .value(let json) = Keychain.read(LLMProviderStore.oauthKeychainKey(for: providerID))
        else { return nil }
        return try? JSONDecoder().decode(LLMOAuthTokens.self, from: Data(json.utf8))
    }

    private func storedTokensAreExpired(providerID: UUID) -> Bool {
        guard OAuthConfig.usesKeychain(environment: ProcessInfo.processInfo.environment),
              let tokens = storedTokens(providerID: providerID) else { return false }
        return tokens.isExpired()
    }

    private func refreshTokens(vendor: LLMOAuthVendor, providerID: UUID) async throws {
        let key = LLMProviderStore.oauthKeychainKey(for: providerID)
        // No refresh token means refresh is impossible; the user must sign in again.
        guard let tokens = storedTokens(providerID: providerID),
              let refreshToken = tokens.refreshToken, !refreshToken.isEmpty
        else { throw LLMClientError.missingCredential }
        let form = LLMOAuth.refreshRequestForm(vendor: vendor, refreshToken: refreshToken)
        let data = try await Self.postForm(LLMOAuth.constants(for: vendor).tokenURL, form)
        var merged = try LLMOAuth.parseTokens(from: data, now: Date())
        if merged.refreshToken?.isEmpty ?? true { merged.refreshToken = refreshToken }
        let encoded = try JSONEncoder().encode(merged)
        try Keychain.set(String(decoding: encoded, as: UTF8.self), forKey: key)
    }

    /// Model listing for the Settings "Fetch models" button.
    func listModels(config: LLMProviderConfig) async throws -> [String] {
        let base = Self.trimmedBase(config.baseURL)
        let path: String
        switch config.kind {
        case .ollama: path = "\(base)/api/tags"
        case .anthropic: path = "\(base)/v1/models"
        case .openAICompatible:
            path = base.hasSuffix("/v1") ? "\(base)/models" : "\(base)/v1/models"
        }
        guard let url = URL(string: path) else { throw LLMClientError.http(0) }
        try LLMEndpoint.validate(url)
        var request = URLRequest(url: url)
        try applyAuth(to: &request, config: config)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw LLMClientError.http(status) }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let models = object["models"] as? [[String: Any]] { // Ollama /api/tags
            return models.compactMap { $0["name"] as? String }.sorted()
        }
        if let rows = object["data"] as? [[String: Any]] { // OpenAI + Anthropic
            return rows.compactMap { $0["id"] as? String }.sorted()
        }
        return []
    }

    static func postForm(_ urlString: String, _ form: [String: String]) async throws -> Data {
        guard let url = URL(string: urlString) else { throw LLMClientError.http(0) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw LLMClientError.http(status) }
        return data
    }
}

/// Raised when the loopback sign-in cannot run at all. Vendor OAuth clients are
/// public and out of our control, so the Settings UI falls back to API keys.
enum LLMOAuthFlowError: LocalizedError {
    case signInUnavailable(vendor: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .signInUnavailable(let vendor, let reason):
            return "Sign in with \(vendor) did not finish. Reason: \(reason). Use API-key mode in Settings → AI."
        }
    }
}

/// Sign in with Claude / ChatGPT: PKCE + loopback redirect, reusing the
/// same listener the Google OAuth flow uses. Stores tokens in the Keychain.
@MainActor
enum LLMOAuthFlow {
    static func signIn(vendor: LLMOAuthVendor, providerID: UUID) async throws {
        guard OAuthConfig.usesKeychain(environment: ProcessInfo.processInfo.environment) else {
            throw LLMClientError.keychainUnavailable
        }
        let constants = LLMOAuth.constants(for: vendor)
        let pkce = LLMOAuth.PKCE.generate()
        let state = UUID().uuidString
        let service = OAuthService()
        // Vendors that registered one fixed redirect URI need that exact port.
        let port: UInt16
        let codeTask: Task<String, Error>
        do {
            (port, codeTask) = try service.startLoopbackListener(
                expectedState: state, preferredPort: constants.fixedPort)
        } catch {
            throw LLMOAuthFlowError.signInUnavailable(
                vendor: Self.name(of: vendor), reason: error.localizedDescription)
        }
        let redirectURI = LLMOAuth.redirectURI(vendor: vendor, port: port)
        let url = LLMOAuth.authorizeURL(vendor: vendor, redirectURI: redirectURI,
                                        state: state, challenge: pkce.challenge)
        NSWorkspace.shared.open(url)
        let code: String
        do {
            code = try await codeTask.value
        } catch {
            codeTask.cancel()
            throw LLMOAuthFlowError.signInUnavailable(
                vendor: Self.name(of: vendor), reason: error.localizedDescription)
        }
        let form = LLMOAuth.tokenRequestForm(vendor: vendor, code: code,
                                             verifier: pkce.verifier, redirectURI: redirectURI)
        let data = try await LLMClient.postForm(constants.tokenURL, form)
        let tokens = try LLMOAuth.parseTokens(from: data, now: Date())
        let encoded = try JSONEncoder().encode(tokens)
        try Keychain.set(String(decoding: encoded, as: UTF8.self),
                         forKey: LLMProviderStore.oauthKeychainKey(for: providerID))
    }

    private static func name(of vendor: LLMOAuthVendor) -> String {
        switch vendor {
        case .claude: return "Claude"
        case .chatGPT: return "ChatGPT"
        }
    }
}
