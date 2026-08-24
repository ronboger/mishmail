import CryptoKit
import Foundation

/// Subscription OAuth for LLM providers (sign in with Claude / ChatGPT /
/// Grok / OpenRouter), the way the Aside browser and Pi do it. Pure:
/// URL/form/JSON math only. The loopback listener, device-code polling,
/// and browser hand-off live in LLMOAuthFlow.
enum LLMOAuth {
    struct Constants {
        let authorizeURL: String
        let tokenURL: String
        let clientID: String
        let scopes: String
        let redirectPath: String
        /// Host the vendor registered for the loopback redirect. Vendors match
        /// the redirect URI as an exact string, so "localhost" and "127.0.0.1"
        /// are not interchangeable. The listener always binds 127.0.0.1.
        let redirectHost: String
        /// Port the vendor registered, or nil when any ephemeral port works.
        let fixedPort: UInt16?
        /// Vendor-specific authorize query additions (e.g. Anthropic's
        /// "code=true", Codex's simplified-flow switches).
        let extraAuthorizeParams: [(String, String)]
        /// Anthropic's token endpoint takes JSON (with the state echoed back);
        /// everyone else takes a classic urlencoded form.
        let tokenBodyIsJSON: Bool
    }

    /// Publicly known Claude Code / Codex CLI / Grok CLI / OpenRouter PKCE
    /// flow constants, verified against Aside and Pi at implementation time.
    /// If a vendor changes them, sign-in fails softly and the UI falls back
    /// to API-key mode.
    static func constants(for vendor: LLMOAuthVendor) -> Constants {
        switch vendor {
        case .claude:
            // Registered redirect is exactly http://localhost:53692/callback.
            return Constants(
                authorizeURL: "https://claude.ai/oauth/authorize",
                tokenURL: "https://platform.claude.com/v1/oauth/token",
                clientID: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
                scopes: "org:create_api_key user:profile user:inference"
                    + " user:sessions:claude_code user:mcp_servers user:file_upload",
                redirectPath: "/callback",
                redirectHost: "localhost",
                fixedPort: 53692,
                extraAuthorizeParams: [("code", "true")],
                tokenBodyIsJSON: true)
        case .chatGPT:
            // The Codex CLI client registers exactly one redirect URI:
            // http://localhost:1455/auth/callback. Any other host, port, or
            // path is rejected by the authorize endpoint.
            return Constants(
                authorizeURL: "https://auth.openai.com/oauth/authorize",
                tokenURL: "https://auth.openai.com/oauth/token",
                clientID: "app_EMoamEEZ73f0CkXaXp7hrann",
                scopes: "openid profile email offline_access",
                redirectPath: "/auth/callback",
                redirectHost: "localhost",
                fixedPort: 1455,
                extraAuthorizeParams: [
                    ("id_token_add_organizations", "true"),
                    ("codex_cli_simplified_flow", "true"),
                    ("originator", "codex_cli_rs"),
                ],
                tokenBodyIsJSON: false)
        case .grok:
            // Grok uses the RFC 8628 device-code flow: no browser redirect,
            // so authorizeURL is the device-code endpoint and redirect fields
            // are unused.
            return Constants(
                authorizeURL: "https://auth.x.ai/oauth2/device/code",
                tokenURL: "https://auth.x.ai/oauth2/token",
                clientID: "b1a00492-073a-47ea-816f-4c329264a828",
                scopes: "openid profile email offline_access grok-cli:access api:access",
                redirectPath: "",
                redirectHost: "",
                fixedPort: nil,
                extraAuthorizeParams: [],
                tokenBodyIsJSON: false)
        case .gemini:
            // Gemini is API-key only. Google's public Gemini CLI desktop
            // client id/secret trip GitHub push protection, and the
            // OpenAI-compat endpoint does not accept those user OAuth tokens.
            return Constants(
                authorizeURL: "https://accounts.google.com/o/oauth2/v2/auth",
                tokenURL: "https://oauth2.googleapis.com/token",
                clientID: "",
                scopes: "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile openid",
                redirectPath: "/oauth2callback",
                redirectHost: "localhost",
                fixedPort: 8085,
                extraAuthorizeParams: [("access_type", "offline"), ("prompt", "consent")],
                tokenBodyIsJSON: false)
        case .openRouter:
            // OpenRouter PKCE (same flow Pi uses): no client id, any
            // localhost port, and the code exchanges for a user-owned API
            // key rather than an expiring access/refresh pair.
            return Constants(
                authorizeURL: "https://openrouter.ai/auth",
                tokenURL: "https://openrouter.ai/api/v1/auth/keys",
                clientID: "",
                scopes: "",
                redirectPath: "/callback",
                redirectHost: "localhost",
                fixedPort: nil,
                extraAuthorizeParams: [],
                tokenBodyIsJSON: true)
        }
    }

    /// OpenRouter does not use OAuth `state`; CSRF is the unguessable
    /// callback path plus PKCE. Other loopback vendors still require state.
    static func usesOAuthState(_ vendor: LLMOAuthVendor) -> Bool {
        vendor != .openRouter && vendor != .grok
    }

    /// OpenRouter mints a user-controlled API key that does not expire
    /// and has no refresh token. A 401 means the key was revoked.
    static func mintsPermanentAPIKey(_ vendor: LLMOAuthVendor) -> Bool {
        vendor == .openRouter
    }

    /// Builds the redirect URI for a vendor from the port the local listener
    /// actually bound. Pure string math so the flow stays testable.
    /// `path` overrides the vendor default so OpenRouter can use a unique
    /// `/callback/<uuid>` (Pi's CSRF stand-in for missing OAuth state).
    static func redirectURI(vendor: LLMOAuthVendor, port: UInt16, path: String? = nil) -> String {
        let constants = constants(for: vendor)
        return "http://\(constants.redirectHost):\(port)\(path ?? constants.redirectPath)"
    }

    struct PKCE {
        let verifier: String
        var challenge: String {
            let digest = SHA256.hash(data: Data(verifier.utf8))
            return Data(digest).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        static func generate() -> PKCE {
            var bytes = [UInt8](repeating: 0, count: 32)
            // If the system CSPRNG refuses, fall back to the standard library
            // generator. A weaker verifier still protects the flow; a constant
            // all-zero verifier (the old discarded-status behaviour) does not.
            if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
                var generator = SystemRandomNumberGenerator()
                bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
            }
            let verifier = Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return PKCE(verifier: verifier)
        }
    }

    static func authorizeURL(vendor: LLMOAuthVendor, redirectURI: String,
                             state: String, challenge: String) -> URL {
        let constants = constants(for: vendor)
        var components = URLComponents(string: constants.authorizeURL)!
        if vendor == .openRouter {
            // OpenRouter's /auth is not a standard OAuth authorize endpoint.
            // It takes callback_url + PKCE and has no client_id or state.
            components.queryItems = [
                URLQueryItem(name: "callback_url", value: redirectURI),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
            ]
            return components.url!
        }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: constants.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: constants.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ] + constants.extraAuthorizeParams.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url!
    }

    /// Authorization-code exchange body. Anthropic requires the state echoed
    /// back inside a JSON body; OpenAI takes a urlencoded form without state.
    /// OpenRouter takes JSON `{code, code_verifier, code_challenge_method}`.
    static func tokenRequestForm(vendor: LLMOAuthVendor, code: String, state: String,
                                 verifier: String, redirectURI: String) -> [String: String] {
        if vendor == .openRouter {
            return [
                "code": code,
                "code_verifier": verifier,
                "code_challenge_method": "S256",
            ]
        }
        var form = [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "client_id": constants(for: vendor).clientID,
        ]
        if constants(for: vendor).tokenBodyIsJSON { form["state"] = state }
        return form
    }

    static func refreshRequestForm(vendor: LLMOAuthVendor,
                                   refreshToken: String) -> [String: String] {
        var form = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": constants(for: vendor).clientID,
        ]
        return form
    }

    static func parseTokens(from data: Data, now: Date) throws -> LLMOAuthTokens {
        struct Response: Decodable {
            let access_token: String?
            let refresh_token: String?
            let expires_in: Int?
            /// OpenRouter's PKCE exchange returns `{ "key": "sk-or-..." }`.
            let key: String?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let access = response.access_token ?? response.key, !access.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription: "token response has no access_token or key"))
        }
        let expiresAt: Date
        if let expiresIn = response.expires_in {
            expiresAt = now.addingTimeInterval(TimeInterval(expiresIn))
        } else if response.access_token == nil {
            // A minted API key has no expiry unless the vendor sent one.
            expiresAt = Date.distantFuture
        } else {
            expiresAt = now.addingTimeInterval(3600)
        }
        return LLMOAuthTokens(
            accessToken: access,
            refreshToken: response.refresh_token,
            expiresAt: expiresAt)
    }

    // MARK: - Grok device-code flow (RFC 8628)

    struct DeviceCode: Equatable, Sendable {
        var deviceCode: String
        var userCode: String
        var verificationURI: String
        /// URI with the user code embedded, when the vendor sends one.
        var verificationURIComplete: String?
        var intervalSeconds: Int
        var expiresInSeconds: Int
    }

    static func deviceCodeRequestForm(vendor: LLMOAuthVendor) -> [String: String] {
        let constants = constants(for: vendor)
        return ["client_id": constants.clientID, "scope": constants.scopes]
    }

    static func parseDeviceCode(from data: Data) throws -> DeviceCode {
        struct Response: Decodable {
            let device_code: String
            let user_code: String
            let verification_uri: String
            let verification_uri_complete: String?
            let interval: Int?
            let expires_in: Int
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return DeviceCode(
            deviceCode: response.device_code,
            userCode: response.user_code,
            verificationURI: response.verification_uri,
            verificationURIComplete: response.verification_uri_complete,
            intervalSeconds: max(response.interval ?? 5, 1),
            expiresInSeconds: response.expires_in)
    }

    static func devicePollForm(vendor: LLMOAuthVendor, deviceCode: String) -> [String: String] {
        ["grant_type": "urn:ietf:params:oauth:grant-type:device_code",
         "client_id": constants(for: vendor).clientID,
         "device_code": deviceCode]
    }

    /// One poll outcome, decided from the HTTP status and the OAuth `error`
    /// field the vendor sends while authorization is still pending.
    enum DevicePollResult: Equatable, Sendable {
        case tokens(LLMOAuthTokens)
        case pending
        case slowDown(intervalSeconds: Int?)
        case failed(String)
    }

    static func classifyDevicePoll(status: Int, data: Data, now: Date) -> DevicePollResult {
        if (200..<300).contains(status), let tokens = try? parseTokens(from: data, now: now) {
            return .tokens(tokens)
        }
        struct ErrorBody: Decodable { let error: String?; let interval: Int? }
        let body = (try? JSONDecoder().decode(ErrorBody.self, from: data)) ?? ErrorBody(error: nil, interval: nil)
        switch body.error {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown(intervalSeconds: body.interval)
        case "access_denied", "authorization_denied": return .failed("authorization was denied")
        case "expired_token": return .failed("device code expired")
        default: return .failed("device token polling failed (HTTP \(status))")
        }
    }
}

struct LLMOAuthTokens: Codable, Equatable, Sendable {
    var accessToken: String
    /// nil when the vendor sent no refresh_token, so callers can tell
    /// "none issued" apart from an empty value.
    var refreshToken: String?
    var expiresAt: Date

    /// A 60-second safety margin so a token that expires mid-request
    /// refreshes up front instead.
    func isExpired(now: Date = Date()) -> Bool {
        now >= expiresAt.addingTimeInterval(-60)
    }
}
