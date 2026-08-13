import CryptoKit
import Foundation

/// Subscription OAuth for LLM providers (sign in with Claude / ChatGPT),
/// the way the Aside browser does it. Pure: URL/form/JSON math only.
/// The loopback listener and browser hand-off live in LLMOAuthFlow.
enum LLMOAuth {
    struct Constants {
        let authorizeURL: String
        let tokenURL: String
        let clientID: String
        let scopes: String
        let redirectPath: String
    }

    /// Publicly known Claude Code / Codex CLI flow constants. Verified at
    /// implementation time; if a vendor changes them, sign-in fails softly
    /// and the UI falls back to API-key mode.
    static func constants(for vendor: LLMOAuthVendor) -> Constants {
        switch vendor {
        case .claude:
            return Constants(
                authorizeURL: "https://claude.ai/oauth/authorize",
                tokenURL: "https://console.anthropic.com/v1/oauth/token",
                clientID: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
                scopes: "org:create_api_key user:profile user:inference",
                redirectPath: "/callback")
        case .chatGPT:
            return Constants(
                authorizeURL: "https://auth.openai.com/oauth/authorize",
                tokenURL: "https://auth.openai.com/oauth/token",
                clientID: "app_EMoamEEZ73f0CkXaXp7hrann",
                scopes: "openid profile email offline_access",
                redirectPath: "/callback")
        }
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
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: constants.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: constants.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }

    static func tokenRequestForm(vendor: LLMOAuthVendor, code: String,
                                 verifier: String, redirectURI: String) -> [String: String] {
        ["grant_type": "authorization_code",
         "code": code,
         "code_verifier": verifier,
         "redirect_uri": redirectURI,
         "client_id": constants(for: vendor).clientID]
    }

    static func refreshRequestForm(vendor: LLMOAuthVendor,
                                   refreshToken: String) -> [String: String] {
        ["grant_type": "refresh_token",
         "refresh_token": refreshToken,
         "client_id": constants(for: vendor).clientID]
    }

    static func parseTokens(from data: Data, now: Date) throws -> LLMOAuthTokens {
        struct Response: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return LLMOAuthTokens(
            accessToken: response.access_token,
            refreshToken: response.refresh_token,
            expiresAt: now.addingTimeInterval(TimeInterval(response.expires_in ?? 3600)))
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
