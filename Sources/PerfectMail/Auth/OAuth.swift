import Foundation
import CryptoKit
import Network
import AppKit

/// OAuth 2.0 Authorization Code + PKCE against Google, using the
/// "Desktop app" client type and a loopback redirect (RFC 8252).
/// The user's default browser handles sign-in; we catch the redirect
/// on 127.0.0.1 with a one-shot listener. No secrets leave the machine.
struct OAuthConfig {
    static let scopes = [
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
    ]
    static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    /// Client ID/secret for the user's own Google Cloud "Desktop app" OAuth
    /// client. For installed apps Google issues a "secret" that is explicitly
    /// not confidential; PKCE provides the actual protection.
    static var clientID: String {
        get { UserDefaults.standard.string(forKey: "oauth.clientID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "oauth.clientID") }
    }
    static var clientSecret: String {
        get { Keychain.get("oauth.clientSecret") ?? "" }
        set { try? Keychain.set(newValue, forKey: "oauth.clientSecret") }
    }
    static var isConfigured: Bool { !clientID.isEmpty }
}

struct TokenResponse: Decodable {
    let access_token: String
    let expires_in: Int
    let refresh_token: String?
}

enum OAuthError: LocalizedError {
    case notConfigured
    case badRedirect
    case authorizationDenied(String)
    case tokenExchangeFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Set your Google OAuth Client ID in Settings first."
        case .badRedirect: return "The sign-in redirect was malformed."
        case .authorizationDenied(let reason): return "Google declined the sign-in: \(reason)."
        case .tokenExchangeFailed(let body): return "Token exchange failed: \(body)"
        case .cancelled: return "Sign-in was cancelled."
        }
    }
}

final class OAuthService {
    /// Runs the full interactive flow and returns (refreshToken, accessToken).
    func signIn() async throws -> (refreshToken: String, accessToken: String) {
        guard OAuthConfig.isConfigured else { throw OAuthError.notConfigured }

        let verifier = Self.randomURLSafe(64)
        let challenge = Self.s256(verifier)
        let state = Self.randomURLSafe(32)

        let (port, codeTask) = try startLoopbackListener(expectedState: state)
        let redirectURI = "http://127.0.0.1:\(port)"

        var comps = URLComponents(string: OAuthConfig.authEndpoint)!
        comps.queryItems = [
            .init(name: "client_id", value: OAuthConfig.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: OAuthConfig.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent select_account"),
        ]
        let authURL = comps.url!
        await MainActor.run { NSWorkspace.shared.open(authURL) }

        let code = try await codeTask.value
        let token = try await exchange(code: code, verifier: verifier, redirectURI: redirectURI)
        guard let refresh = token.refresh_token else {
            throw OAuthError.tokenExchangeFailed("no refresh_token returned")
        }
        return (refresh, token.access_token)
    }

    /// Refreshes an access token from a stored refresh token.
    static func refreshAccessToken(refreshToken: String) async throws -> (token: String, expiresIn: Int) {
        let body = [
            "client_id": OAuthConfig.clientID,
            "client_secret": OAuthConfig.clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        let resp: TokenResponse = try await postForm(OAuthConfig.tokenEndpoint, body)
        return (resp.access_token, resp.expires_in)
    }

    private func exchange(code: String, verifier: String, redirectURI: String) async throws -> TokenResponse {
        let body = [
            "client_id": OAuthConfig.clientID,
            "client_secret": OAuthConfig.clientSecret,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]
        return try await Self.postForm(OAuthConfig.tokenEndpoint, body)
    }

    private static func postForm<T: Decodable>(_ urlString: String, _ form: [String: String]) async throws -> T {
        var req = URLRequest(url: URL(string: urlString)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw OAuthError.tokenExchangeFailed(String(data: data, encoding: .utf8) ?? "unknown")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Loopback listener

    /// Starts a one-shot HTTP listener on an ephemeral 127.0.0.1 port and
    /// returns the port plus a task that resolves to the auth code.
    private func startLoopbackListener(expectedState: String) throws -> (UInt16, Task<String, Error>) {
        // Bind to 127.0.0.1 only (RFC 8252 §8.3): the redirect catcher must
        // not be reachable from other machines on the network.
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        let stream = AsyncThrowingStream<String, Error> { continuation in
            listener.newConnectionHandler = { conn in
                conn.start(queue: .global())
                conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, _ in
                    // Browsers open speculative connections and request
                    // /favicon.ico; ignore anything that isn't the actual
                    // OAuth redirect instead of tearing the listener down.
                    guard let data, let request = String(data: data, encoding: .utf8),
                          let firstLine = request.split(separator: "\r\n").first,
                          let pathPart = firstLine.split(separator: " ").dropFirst().first,
                          let comps = URLComponents(string: String(pathPart)),
                          let items = comps.queryItems,
                          items.contains(where: { $0.name == "code" || $0.name == "error" }) else {
                        conn.cancel()
                        return
                    }
                    let code = items.first { $0.name == "code" }?.value
                    let state = items.first { $0.name == "state" }?.value
                    let errorParam = items.first { $0.name == "error" }?.value
                    let ok = code != nil && state == expectedState
                    let html = ok
                        ? "<html><body style='font-family:-apple-system'><h2>Signed in.</h2>You can close this tab and return to PerfectMail.</body></html>"
                        : "<html><body style='font-family:-apple-system'><h2>Sign-in failed.</h2>You can close this tab and try again from PerfectMail.</body></html>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                    conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        conn.cancel()
                        if ok, let code {
                            continuation.yield(code); continuation.finish()
                        } else if let errorParam {
                            // Surface Google's actual reason (e.g. access_denied)
                            // rather than a generic malformed-redirect message.
                            continuation.finish(throwing: OAuthError.authorizationDenied(errorParam))
                        } else {
                            continuation.finish(throwing: OAuthError.badRedirect)
                        }
                    })
                }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let err) = state { continuation.finish(throwing: err) }
            }
            continuation.onTermination = { _ in listener.cancel() }
        }
        listener.start(queue: .global())
        // Wait briefly for the port to be assigned.
        var port: UInt16 = 0
        for _ in 0..<100 {
            if let p = listener.port?.rawValue, p != 0 { port = p; break }
            usleep(10_000)
        }
        guard port != 0 else { listener.cancel(); throw OAuthError.badRedirect }
        let task = Task<String, Error> {
            for try await code in stream { return code }
            throw OAuthError.cancelled
        }
        return (port, task)
    }

    // MARK: - PKCE helpers

    private static func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private static func s256(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncoded()
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
