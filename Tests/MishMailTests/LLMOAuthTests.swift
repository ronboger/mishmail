import XCTest

final class LLMOAuthTests: XCTestCase {
    func testPKCEGeneratesURLSafeVerifierAndS256Challenge() {
        let pkce = LLMOAuth.PKCE.generate()
        XCTAssertGreaterThanOrEqual(pkce.verifier.count, 43)
        XCTAssertFalse(pkce.challenge.contains("="))
        XCTAssertFalse(pkce.challenge.contains("+"))
        XCTAssertFalse(pkce.challenge.contains("/"))
        // Deterministic check against a known vector (RFC 7636 appendix B).
        let known = LLMOAuth.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(known.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testAuthorizeURLCarriesRequiredParameters() throws {
        let url = LLMOAuth.authorizeURL(
            vendor: .claude, redirectURI: "http://127.0.0.1:53682/callback",
            state: "st8", challenge: "ch4")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["state"], "st8")
        XCTAssertEqual(query["code_challenge"], "ch4")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["redirect_uri"], "http://127.0.0.1:53682/callback")
        XCTAssertEqual(query["client_id"], LLMOAuth.constants(for: .claude).clientID)
        // Anthropic's authorize endpoint requires code=true (Aside/Claude Code flow).
        XCTAssertEqual(query["code"], "true")
    }

    func testChatGPTAuthorizeURLCarriesCodexFlowSwitches() {
        let url = LLMOAuth.authorizeURL(
            vendor: .chatGPT, redirectURI: "http://localhost:1455/auth/callback",
            state: "s", challenge: "c")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["id_token_add_organizations"], "true")
        XCTAssertEqual(query["codex_cli_simplified_flow"], "true")
        XCTAssertEqual(query["originator"], "codex_cli_rs")
    }

    func testParseTokensComputesExpiry() throws {
        let json = #"{"access_token":"at1","refresh_token":"rt1","expires_in":3600}"#
        let now = Date(timeIntervalSince1970: 1_000_000)
        let tokens = try LLMOAuth.parseTokens(from: Data(json.utf8), now: now)
        XCTAssertEqual(tokens.accessToken, "at1")
        XCTAssertEqual(tokens.refreshToken, "rt1")
        XCTAssertFalse(tokens.isExpired(now: now))
        XCTAssertTrue(tokens.isExpired(now: now.addingTimeInterval(3600)))
    }

    func testParseTokensKeepsMissingRefreshTokenNil() throws {
        let json = #"{"access_token":"at2","expires_in":60}"#
        let tokens = try LLMOAuth.parseTokens(from: Data(json.utf8), now: Date())
        XCTAssertEqual(tokens.accessToken, "at2")
        XCTAssertNil(tokens.refreshToken)
    }

    func testRedirectURIMatchesTheRegisteredClient() {
        // The Codex CLI client registers exactly one redirect URI.
        let chatGPT = LLMOAuth.constants(for: .chatGPT)
        XCTAssertEqual(chatGPT.fixedPort, 1455)
        XCTAssertEqual(LLMOAuth.redirectURI(vendor: .chatGPT, port: 1455),
                       "http://localhost:1455/auth/callback")
        // Anthropic registers exactly http://localhost:53692/callback.
        let claude = LLMOAuth.constants(for: .claude)
        XCTAssertEqual(claude.fixedPort, 53692)
        XCTAssertEqual(LLMOAuth.redirectURI(vendor: .claude, port: 53692),
                       "http://localhost:53692/callback")
        XCTAssertEqual(claude.tokenURL, "https://platform.claude.com/v1/oauth/token")
        XCTAssertTrue(claude.tokenBodyIsJSON)
    }

    func testRefreshFormContainsGrantAndClient() {
        let form = LLMOAuth.refreshRequestForm(vendor: .chatGPT, refreshToken: "rt9")
        XCTAssertEqual(form["grant_type"], "refresh_token")
        XCTAssertEqual(form["refresh_token"], "rt9")
        XCTAssertEqual(form["client_id"], LLMOAuth.constants(for: .chatGPT).clientID)
    }

    func testClaudeTokenFormEchoesState() {
        let form = LLMOAuth.tokenRequestForm(
            vendor: .claude, code: "c0", state: "st1", verifier: "v1",
            redirectURI: "http://localhost:53692/callback")
        XCTAssertEqual(form["state"], "st1")
        XCTAssertEqual(form["grant_type"], "authorization_code")
        // OpenAI's form must not carry state.
        let openAI = LLMOAuth.tokenRequestForm(
            vendor: .chatGPT, code: "c0", state: "st1", verifier: "v1",
            redirectURI: "http://localhost:1455/auth/callback")
        XCTAssertNil(openAI["state"])
    }

    func testOpenRouterPKCEAuthorizeAndKeyExchange() throws {
        let constants = LLMOAuth.constants(for: .openRouter)
        XCTAssertEqual(constants.authorizeURL, "https://openrouter.ai/auth")
        XCTAssertEqual(constants.tokenURL, "https://openrouter.ai/api/v1/auth/keys")
        XCTAssertTrue(constants.clientID.isEmpty)
        XCTAssertNil(constants.fixedPort)
        XCTAssertTrue(constants.tokenBodyIsJSON)
        XCTAssertTrue(LLMOAuth.mintsPermanentAPIKey(.openRouter))
        XCTAssertFalse(LLMOAuth.usesOAuthState(.openRouter))
        XCTAssertFalse(LLMOAuth.mintsPermanentAPIKey(.claude))
        XCTAssertTrue(LLMOAuth.usesOAuthState(.claude))

        let path = "/callback/\(UUID().uuidString)"
        let redirect = LLMOAuth.redirectURI(vendor: .openRouter, port: 51423, path: path)
        XCTAssertEqual(redirect, "http://localhost:51423\(path)")

        let url = LLMOAuth.authorizeURL(
            vendor: .openRouter, redirectURI: redirect, state: "unused", challenge: "ch4")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["callback_url"], redirect)
        XCTAssertEqual(query["code_challenge"], "ch4")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertNil(query["client_id"])
        XCTAssertNil(query["redirect_uri"])
        XCTAssertNil(query["state"])
        XCTAssertNil(query["response_type"])

        let form = LLMOAuth.tokenRequestForm(
            vendor: .openRouter, code: "c0", state: "st", verifier: "v1",
            redirectURI: redirect)
        XCTAssertEqual(form["code"], "c0")
        XCTAssertEqual(form["code_verifier"], "v1")
        XCTAssertEqual(form["code_challenge_method"], "S256")
        XCTAssertNil(form["grant_type"])
        XCTAssertNil(form["client_id"])
        XCTAssertNil(form["redirect_uri"])
        XCTAssertNil(form["state"])
    }

    func testParseTokensAcceptsOpenRouterKey() throws {
        let json = #"{"key":"sk-or-v1-abc"}"#
        let now = Date(timeIntervalSince1970: 1_000_000)
        let tokens = try LLMOAuth.parseTokens(from: Data(json.utf8), now: now)
        XCTAssertEqual(tokens.accessToken, "sk-or-v1-abc")
        XCTAssertNil(tokens.refreshToken)
        XCTAssertFalse(tokens.isExpired(now: now))
        XCTAssertFalse(tokens.isExpired(now: now.addingTimeInterval(365 * 24 * 60 * 60)))
    }

    func testParseTokensPrefersAccessTokenOverKey() throws {
        let json = #"{"access_token":"at","key":"sk-or-v1-abc","expires_in":60}"#
        let now = Date(timeIntervalSince1970: 1_000_000)
        let tokens = try LLMOAuth.parseTokens(from: Data(json.utf8), now: now)
        XCTAssertEqual(tokens.accessToken, "at")
        XCTAssertTrue(tokens.isExpired(now: now.addingTimeInterval(60)))
    }

    func testParseTokensRejectsEmptyBody() {
        XCTAssertThrowsError(try LLMOAuth.parseTokens(from: Data(#"{}"#.utf8), now: Date()))
    }

    func testGeminiOAuthConstantsAndForms() {
        let gemini = LLMOAuth.constants(for: .gemini)
        XCTAssertEqual(gemini.authorizeURL, "https://accounts.google.com/o/oauth2/v2/auth")
        XCTAssertEqual(gemini.tokenURL, "https://oauth2.googleapis.com/token")
        XCTAssertTrue(gemini.clientID.isEmpty)
        XCTAssertEqual(gemini.fixedPort, 8085)
        XCTAssertEqual(LLMOAuth.redirectURI(vendor: .gemini, port: 8085), "http://localhost:8085/oauth2callback")
        XCTAssertFalse(gemini.tokenBodyIsJSON)

        let url = LLMOAuth.authorizeURL(
            vendor: .gemini, redirectURI: "http://localhost:8085/oauth2callback",
            state: "st", challenge: "ch")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["access_type"], "offline")
        XCTAssertEqual(query["prompt"], "consent")

        let tokenForm = LLMOAuth.tokenRequestForm(
            vendor: .gemini, code: "c1", state: "st", verifier: "v1",
            redirectURI: "http://localhost:8085/oauth2callback")
        XCTAssertEqual(tokenForm["grant_type"], "authorization_code")
        XCTAssertEqual(tokenForm["code"], "c1")
        XCTAssertEqual(tokenForm["code_verifier"], "v1")
        XCTAssertEqual(tokenForm["redirect_uri"], "http://localhost:8085/oauth2callback")
        XCTAssertNil(tokenForm["client_secret"])

        let refreshForm = LLMOAuth.refreshRequestForm(vendor: .gemini, refreshToken: "rt1")
        XCTAssertEqual(refreshForm["grant_type"], "refresh_token")
        XCTAssertEqual(refreshForm["refresh_token"], "rt1")
        XCTAssertNil(refreshForm["client_secret"])
    }

    func testGrokDeviceCodeFlowMath() throws {
        let constants = LLMOAuth.constants(for: .grok)
        XCTAssertEqual(constants.authorizeURL, "https://auth.x.ai/oauth2/device/code")
        XCTAssertEqual(constants.tokenURL, "https://auth.x.ai/oauth2/token")
        let json = #"{"device_code":"dc","user_code":"AB-12","verification_uri":"https://x.ai/d","interval":5,"expires_in":600}"#
        let device = try LLMOAuth.parseDeviceCode(from: Data(json.utf8))
        XCTAssertEqual(device.userCode, "AB-12")
        XCTAssertEqual(device.intervalSeconds, 5)
        let poll = LLMOAuth.devicePollForm(vendor: .grok, deviceCode: device.deviceCode)
        XCTAssertEqual(poll["grant_type"], "urn:ietf:params:oauth:grant-type:device_code")
        XCTAssertEqual(poll["device_code"], "dc")
    }

    func testDevicePollClassification() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let pending = LLMOAuth.classifyDevicePoll(
            status: 400, data: Data(#"{"error":"authorization_pending"}"#.utf8), now: now)
        XCTAssertEqual(pending, .pending)
        let slow = LLMOAuth.classifyDevicePoll(
            status: 400, data: Data(#"{"error":"slow_down","interval":9}"#.utf8), now: now)
        XCTAssertEqual(slow, .slowDown(intervalSeconds: 9))
        let denied = LLMOAuth.classifyDevicePoll(
            status: 403, data: Data(#"{"error":"access_denied"}"#.utf8), now: now)
        XCTAssertEqual(denied, .failed("authorization was denied"))
        let ok = LLMOAuth.classifyDevicePoll(
            status: 200,
            data: Data(#"{"access_token":"at","refresh_token":"rt","expires_in":3600}"#.utf8),
            now: now)
        if case .tokens(let tokens) = ok {
            XCTAssertEqual(tokens.accessToken, "at")
        } else {
            XCTFail("expected tokens, got \(ok)")
        }
    }
}
