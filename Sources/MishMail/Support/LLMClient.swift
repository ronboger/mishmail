import AppKit
import Foundation

enum LLMClientError: LocalizedError {
    case missingCredential
    case http(Int)
    case keychainUnavailable
    case untrustedEndpoint(String)

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "No API key or sign-in for this provider. Add one in Settings → AI."
        case .http(let code):
            return "The model provider returned HTTP \(code)."
        case .keychainUnavailable:
            return "Keychain is unavailable. Unlock your Mac and try again."
        case .untrustedEndpoint(let host):
            return "Mail would go to \(host). Open Settings → AI, edit this provider, and confirm that host."
        }
    }
}

/// One streaming client for every provider kind. Builds requests with the
/// pure wire codecs, streams SSE/NDJSON lines through the matching
/// StreamState, refreshes OAuth tokens on 401 (single retry).
actor LLMClient {
    static let shared = LLMClient()

    /// One in-flight refresh per provider. The actor is reentrant across
    /// awaits, so two concurrent streams would otherwise both POST the same
    /// refresh token. OpenAI rotates the refresh token on use, which makes the
    /// second POST fail and destroys the sign-in. Callers join instead.
    private var refreshTasks: [UUID: Task<Void, Error>] = [:]

    /// `task` only affects local (Ollama) requests, where thinking effort and
    /// the output cap are per-task. Remote providers ignore it.
    func stream(messages: [LLMMessage], tools: [LLMToolSpec],
                config: LLMProviderConfig, model: String,
                task: LLMTask, maxOutputTokens: Int? = nil) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let streamTask = Task {
                do {
                    try await self.run(messages: messages, tools: tools, config: config,
                                       model: model, task: task,
                                       maxOutputTokens: maxOutputTokens,
                                       allowRefresh: true) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in streamTask.cancel() }
        }
    }

    private func run(messages: [LLMMessage], tools: [LLMToolSpec],
                     config: LLMProviderConfig, model: String, task: LLMTask,
                     maxOutputTokens: Int?,
                     allowRefresh: Bool,
                     yield: @Sendable (LLMEvent) -> Void) async throws {
        // Refresh up front when the stored token already expired, so the common
        // case costs one request instead of a 401 plus a retry. A failure here
        // is not fatal: the stale token still gets its 401 retry below.
        if allowRefresh, case .oauth(let vendor) = config.authMode,
           storedTokensAreExpired(providerID: config.id) {
            try? await refreshTokens(vendor: vendor, providerID: config.id)
        }
        let request = try await buildRequest(messages: messages, tools: tools,
                                            config: config, model: model, task: task,
                                            maxOutputTokens: maxOutputTokens)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, allowRefresh, case .oauth(let vendor) = config.authMode {
            try await refreshTokens(vendor: vendor, providerID: config.id)
            return try await run(messages: messages, tools: tools, config: config,
                                 model: model, task: task,
                                 maxOutputTokens: maxOutputTokens,
                                 allowRefresh: false, yield: yield)
        }
        guard (200..<300).contains(status) else {
            if config.kind == .ollama, let failure = Ollama.chatFailure(status: status, model: model) {
                throw failure
            }
            throw LLMClientError.http(status)
        }

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
        var deduper = LLMDoneDeduper()
        func emit(_ events: [LLMEvent]) {
            for event in deduper.accept(events) { yield(event) }
        }
        for try await line in bytes.lines {
            emit(consume(line))
        }
        if !deduper.sawDone { emit(finalFlush()) }
        if !deduper.sawDone { emit([.done(stopReason: "stop", usage: nil)]) }
    }

    private func buildRequest(messages: [LLMMessage], tools: [LLMToolSpec],
                              config: LLMProviderConfig, model: String,
                              task: LLMTask,
                              maxOutputTokens: Int?) async throws -> URLRequest {
        let path = LLMEndpoint.chatPath(kind: config.kind, base: config.baseURL)
        let body: Data
        switch config.kind {
        case .openAICompatible:
            body = try OpenAIWire.requestBody(model: model, messages: messages, tools: tools)
        case .anthropic:
            body = try AnthropicWire.requestBody(model: model, messages: messages,
                                                 tools: tools, maxTokens: 8192)
        case .ollama:
            // A thinking *level* on a model without the capability fails the
            // request, so fall back to the model's own default there. `off` is
            // always safe and needs no check.
            var thinking = Ollama.thinking(for: task)
            if case .level = thinking, await !Ollama.supportsThinking(model: model) {
                thinking = .modelDefault
            }
            body = try OllamaChatWire.requestBody(
                model: model, messages: messages, tools: tools,
                keepAliveSeconds: Ollama.keepAliveSeconds,
                contextTokens: Ollama.contextTokens,
                thinking: thinking,
                maxOutputTokens: maxOutputTokens ?? Ollama.maxOutputTokens(for: task))
            await Ollama.LoadedModels.shared.note(model)
        }
        guard let url = URL(string: path) else { throw LLMClientError.http(0) }
        if config.kind == .ollama {
            try Ollama.validateEndpoint(url)
        } else {
            try LLMEndpoint.validate(url)
            if !LLMProviderStore.hasHostConsent(for: config) {
                throw LLMClientError.untrustedEndpoint(
                    LLMRemotePolicy.host(of: config.baseURL) ?? config.baseURL)
            }
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        try applyAuth(to: &request, config: config)
        return request
    }

    private func applyAuth(to request: inout URLRequest, config: LLMProviderConfig) throws {
        if config.kind == .ollama { return } // local, keyless
        guard OAuthConfig.usesKeychain(environment: ProcessInfo.processInfo.environment) else {
            throw LLMClientError.missingCredential // fixture builds never touch Keychain
        }
        switch config.authMode {
        case .apiKey:
            let key = try Self.requiredSecret(LLMProviderStore.keychainKey(for: config.id))
            switch config.kind {
            case .anthropic:
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            default:
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        case .oauth:
            let tokens = try requiredTokens(providerID: config.id)
            request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
            if config.kind == .anthropic {
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            }
        }
    }

    /// A locked or otherwise unreadable Keychain is not a missing credential:
    /// reporting it as one would tell the user to sign in again and throw away
    /// a sign-in that is still there.
    private static func requiredSecret(_ key: String) throws -> String {
        switch Keychain.read(key) {
        case .value(let value): return value
        case .notFound: throw LLMClientError.missingCredential
        case .unavailable: throw LLMClientError.keychainUnavailable
        }
    }

    private func requiredTokens(providerID: UUID) throws -> LLMOAuthTokens {
        let json = try Self.requiredSecret(LLMProviderStore.oauthKeychainKey(for: providerID))
        guard let tokens = try? JSONDecoder().decode(LLMOAuthTokens.self, from: Data(json.utf8))
        else { throw LLMClientError.missingCredential }
        return tokens
    }

    private func storedTokensAreExpired(providerID: UUID) -> Bool {
        guard OAuthConfig.usesKeychain(environment: ProcessInfo.processInfo.environment),
              let tokens = try? requiredTokens(providerID: providerID) else { return false }
        return tokens.isExpired()
    }

    /// Joins the in-flight refresh for this provider, or starts one. The stored
    /// task outlives any single caller's cancellation, so a cancelled stream
    /// cannot leave a half-done rotation behind.
    private func refreshTokens(vendor: LLMOAuthVendor, providerID: UUID) async throws {
        if let inFlight = refreshTasks[providerID] {
            return try await inFlight.value
        }
        let task = Task { try await self.performRefresh(vendor: vendor, providerID: providerID) }
        refreshTasks[providerID] = task
        defer { refreshTasks[providerID] = nil }
        try await task.value
    }

    private func performRefresh(vendor: LLMOAuthVendor, providerID: UUID) async throws {
        let key = LLMProviderStore.oauthKeychainKey(for: providerID)
        // No refresh token means refresh is impossible; the user must sign in again.
        let tokens = try requiredTokens(providerID: providerID)
        guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty
        else { throw LLMClientError.missingCredential }
        let form = LLMOAuth.refreshRequestForm(vendor: vendor, refreshToken: refreshToken)
        let data = try await Self.postToken(vendor: vendor, form)
        var merged = try LLMOAuth.parseTokens(from: data, now: Date())
        if merged.refreshToken?.isEmpty ?? true { merged.refreshToken = refreshToken }
        let encoded = try JSONEncoder().encode(merged)
        try Keychain.set(String(decoding: encoded, as: UTF8.self), forKey: key)
    }

    /// Model listing for the Settings "Fetch models" button.
    func listModels(config: LLMProviderConfig) async throws -> [String] {
        // Same OAuth handling as `stream`: refresh an already-expired token up
        // front, and refresh once more on a 401 before one retry.
        if case .oauth(let vendor) = config.authMode,
           storedTokensAreExpired(providerID: config.id) {
            try? await refreshTokens(vendor: vendor, providerID: config.id)
        }
        return try await runListModels(config: config, allowRefresh: true)
    }

    private func runListModels(config: LLMProviderConfig,
                               allowRefresh: Bool) async throws -> [String] {
        let path = LLMEndpoint.modelsPath(kind: config.kind, base: config.baseURL)
        guard let url = URL(string: path) else { throw LLMClientError.http(0) }
        if config.kind == .ollama {
            try Ollama.validateEndpoint(url)
        } else {
            try LLMEndpoint.validate(url)
        }
        var request = URLRequest(url: url)
        try applyAuth(to: &request, config: config)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, allowRefresh, case .oauth(let vendor) = config.authMode {
            try await refreshTokens(vendor: vendor, providerID: config.id)
            return try await runListModels(config: config, allowRefresh: false)
        }
        guard (200..<300).contains(status) else { throw LLMClientError.http(status) }
        return LLMEndpoint.modelNames(fromJSONObject: try? JSONSerialization.jsonObject(with: data))
    }

    static func postForm(_ urlString: String, _ form: [String: String]) async throws -> Data {
        let (status, data) = try await postFormRaw(urlString, form)
        guard (200..<300).contains(status) else { throw LLMClientError.http(status) }
        return data
    }

    /// Form POST that also returns error bodies, for device-code polling where
    /// "authorization_pending" arrives as a 4xx with a JSON body.
    static func postFormRaw(_ urlString: String,
                            _ form: [String: String]) async throws -> (Int, Data) {
        guard let url = URL(string: urlString) else { throw LLMClientError.http(0) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// Anthropic's OAuth token endpoint takes JSON, not a urlencoded form.
    static func postJSON(_ urlString: String, _ body: [String: String]) async throws -> Data {
        guard let url = URL(string: urlString) else { throw LLMClientError.http(0) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw LLMClientError.http(status) }
        return data
    }

    /// Token-endpoint POST in whichever encoding the vendor requires.
    static func postToken(vendor: LLMOAuthVendor, _ form: [String: String]) async throws -> Data {
        let constants = LLMOAuth.constants(for: vendor)
        if constants.tokenBodyIsJSON {
            return try await postJSON(constants.tokenURL, form)
        }
        return try await postForm(constants.tokenURL, form)
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
    /// `onUserCode` fires for device-code vendors (Grok) so the UI can show
    /// the code the user must confirm in the browser.
    static func signIn(vendor: LLMOAuthVendor, providerID: UUID,
                       onUserCode: ((String, String) -> Void)? = nil) async throws {
        guard OAuthConfig.usesKeychain(environment: ProcessInfo.processInfo.environment) else {
            throw LLMClientError.keychainUnavailable
        }
        if vendor == .grok {
            return try await signInDeviceCode(vendor: vendor, providerID: providerID,
                                              onUserCode: onUserCode)
        }
        let constants = LLMOAuth.constants(for: vendor)
        guard !constants.clientID.isEmpty else {
            throw LLMOAuthFlowError.signInUnavailable(
                vendor: Self.name(of: vendor),
                reason: "Client ID is not configured. Add your OAuth credentials or use an API key in Settings → AI.")
        }
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
        let form = LLMOAuth.tokenRequestForm(vendor: vendor, code: code, state: state,
                                             verifier: pkce.verifier, redirectURI: redirectURI)
        let data = try await LLMClient.postToken(vendor: vendor, form)
        try store(tokenData: data, providerID: providerID)
    }

    /// RFC 8628 device-code sign-in (Grok): show a code, open the browser,
    /// poll the token endpoint until the user confirms.
    private static func signInDeviceCode(vendor: LLMOAuthVendor, providerID: UUID,
                                         onUserCode: ((String, String) -> Void)?) async throws {
        let constants = LLMOAuth.constants(for: vendor)
        let device: LLMOAuth.DeviceCode
        do {
            let data = try await LLMClient.postForm(
                constants.authorizeURL, LLMOAuth.deviceCodeRequestForm(vendor: vendor))
            device = try LLMOAuth.parseDeviceCode(from: data)
        } catch {
            throw LLMOAuthFlowError.signInUnavailable(
                vendor: name(of: vendor), reason: error.localizedDescription)
        }
        let verificationURI = device.verificationURIComplete ?? device.verificationURI
        onUserCode?(device.userCode, verificationURI)
        if let url = URL(string: verificationURI), url.scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        var interval = device.intervalSeconds
        let deadline = Date().addingTimeInterval(TimeInterval(device.expiresInSeconds))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            let (status, data) = try await LLMClient.postFormRaw(
                constants.tokenURL,
                LLMOAuth.devicePollForm(vendor: vendor, deviceCode: device.deviceCode))
            switch LLMOAuth.classifyDevicePoll(status: status, data: data, now: Date()) {
            case .tokens(let tokens):
                let encoded = try JSONEncoder().encode(tokens)
                try Keychain.set(String(decoding: encoded, as: UTF8.self),
                                 forKey: LLMProviderStore.oauthKeychainKey(for: providerID))
                return
            case .pending:
                continue
            case .slowDown(let seconds):
                interval = seconds ?? (interval + 5)
            case .failed(let reason):
                throw LLMOAuthFlowError.signInUnavailable(vendor: name(of: vendor), reason: reason)
            }
        }
        throw LLMOAuthFlowError.signInUnavailable(
            vendor: name(of: vendor), reason: "device code expired before the sign-in finished")
    }

    private static func store(tokenData: Data, providerID: UUID) throws {
        let tokens = try LLMOAuth.parseTokens(from: tokenData, now: Date())
        let encoded = try JSONEncoder().encode(tokens)
        try Keychain.set(String(decoding: encoded, as: UTF8.self),
                         forKey: LLMProviderStore.oauthKeychainKey(for: providerID))
    }

    private static func name(of vendor: LLMOAuthVendor) -> String {
        switch vendor {
        case .claude: return "Claude"
        case .chatGPT: return "ChatGPT"
        case .grok: return "Grok"
        case .gemini: return "Google Gemini"
        }
    }
}
