import Foundation

/// Settings for the built-in local Ollama provider.
enum Ollama {
    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: "ollama.url") ?? "http://127.0.0.1:11434" }
        set { UserDefaults.standard.set(newValue, forKey: "ollama.url") }
    }
    static var model: String {
        get { UserDefaults.standard.string(forKey: "ollama.model") ?? "llama3.2" }
        set { UserDefaults.standard.set(newValue, forKey: "ollama.model") }
    }

    /// User explicitly allowed sending mail content to a non-loopback Ollama
    /// endpoint (Settings → AI). Loopback never needs this.
    static var allowRemoteEndpoint: Bool {
        get { UserDefaults.standard.bool(forKey: "ollama.allowRemote") }
        set { UserDefaults.standard.set(newValue, forKey: "ollama.allowRemote") }
    }

    enum OllamaError: LocalizedError {
        case insecureEndpoint
        case remoteNotAllowed
        var errorDescription: String? {
            switch self {
            case .insecureEndpoint:
                return "Ollama endpoint \(Ollama.baseURL) is neither local nor HTTPS. Your email content won't be sent over an unencrypted connection to a remote host — use http://127.0.0.1:11434 or an https:// URL."
            case .remoteNotAllowed:
                return "Ollama endpoint \(Ollama.baseURL) is not on this Mac. Enable “Allow remote Ollama” in Settings → AI if you intend to send mail content there over HTTPS."
            }
        }
    }

    /// True when the configured endpoint is this machine.
    static var isLoopback: Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// Shared endpoint guard: loopback OK; remote must be HTTPS *and*
    /// explicitly opted in.
    /// `isLoopback` reads the global `Ollama.baseURL`, so this assumes the
    /// built-in row is the only Ollama provider; a second Ollama-kind row
    /// would need a URL-argument-based check.
    static func validateEndpoint(_ url: URL) throws {
        if isLoopback { return }
        if url.scheme?.lowercased() != "https" { throw OllamaError.insecureEndpoint }
        if !allowRemoteEndpoint { throw OllamaError.remoteNotAllowed }
    }
}
