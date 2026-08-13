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
        // Claude takes any ephemeral loopback port.
        let claude = LLMOAuth.constants(for: .claude)
        XCTAssertNil(claude.fixedPort)
        XCTAssertEqual(LLMOAuth.redirectURI(vendor: .claude, port: 53682),
                       "http://127.0.0.1:53682/callback")
    }

    func testRefreshFormContainsGrantAndClient() {
        let form = LLMOAuth.refreshRequestForm(vendor: .chatGPT, refreshToken: "rt9")
        XCTAssertEqual(form["grant_type"], "refresh_token")
        XCTAssertEqual(form["refresh_token"], "rt9")
        XCTAssertEqual(form["client_id"], LLMOAuth.constants(for: .chatGPT).clientID)
    }
}
