import Foundation

/// Minimal client for a local Ollama server — AI drafting that never leaves
/// the machine. Off unless Ollama is running.
enum Ollama {
    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: "ollama.url") ?? "http://127.0.0.1:11434" }
        set { UserDefaults.standard.set(newValue, forKey: "ollama.url") }
    }
    static var model: String {
        get { UserDefaults.standard.string(forKey: "ollama.model") ?? "llama3.2" }
        set { UserDefaults.standard.set(newValue, forKey: "ollama.model") }
    }

    struct GenerateResponse: Decodable { let response: String }

    enum OllamaError: LocalizedError {
        case unreachable
        case insecureEndpoint
        var errorDescription: String? {
            switch self {
            case .unreachable:
                return "Couldn't reach Ollama at \(Ollama.baseURL). Install it from ollama.com and run: ollama pull \(Ollama.model)"
            case .insecureEndpoint:
                return "Ollama endpoint \(Ollama.baseURL) is neither local nor HTTPS. Your email content won't be sent over an unencrypted connection to a remote host — use http://127.0.0.1:11434 or an https:// URL."
            }
        }
    }

    /// True when the configured endpoint is this machine.
    static var isLoopback: Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    static func generate(prompt: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/api/generate") else { throw OllamaError.unreachable }
        // Never send message content in cleartext to a non-local host.
        if !isLoopback, url.scheme?.lowercased() != "https" { throw OllamaError.insecureEndpoint }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "prompt": prompt, "stream": false,
        ])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw OllamaError.unreachable }
            return try JSONDecoder().decode(GenerateResponse.self, from: data).response
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is OllamaError {
            throw OllamaError.unreachable
        } catch let error as DecodingError {
            throw error
        } catch {
            throw OllamaError.unreachable
        }
    }

    static func draftReply(originalFrom: String, originalBody: String, intent: String, userEmail: String) -> String {
        """
        You are drafting an email reply on behalf of \(userEmail). \
        Write only the reply body — no subject line, no explanations, no placeholders like [Name]. \
        Match a concise, friendly, professional tone.

        Original message from \(originalFrom):
        ---
        \(String(originalBody.prefix(4000)))
        ---

        What the reply should say: \(intent.isEmpty ? "a brief, appropriate response" : intent)
        """
    }
}
