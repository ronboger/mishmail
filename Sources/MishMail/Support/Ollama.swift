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

    /// Seconds Ollama keeps the weights in memory after a reply (`keep_alive`).
    /// 0 unloads at once; a negative value keeps the model loaded for good.
    /// Ollama's own default is 300, which leaves several gigabytes resident long
    /// after a one-off draft or triage run.
    static var keepAliveSeconds: Int {
        get {
            UserDefaults.standard.object(forKey: "ollama.keepAlive") as? Int
                ?? defaultKeepAliveSeconds
        }
        set { UserDefaults.standard.set(newValue, forKey: "ollama.keepAlive") }
    }
    static let defaultKeepAliveSeconds = 60

    /// Context window sent as `options.num_ctx`. This sizes the KV cache, so a
    /// model whose own context length is 256k allocates far more memory than a
    /// mail assistant ever fills. 0 means "use the server's value".
    static var contextTokens: Int {
        get {
            UserDefaults.standard.object(forKey: "ollama.numCtx") as? Int
                ?? defaultContextTokens
        }
        set { UserDefaults.standard.set(newValue, forKey: "ollama.numCtx") }
    }
    static let defaultContextTokens = 16_384

    /// User explicitly allowed sending mail content to a non-loopback Ollama
    /// endpoint (Settings → AI). Loopback never needs this.
    static var allowRemoteEndpoint: Bool {
        get { UserDefaults.standard.bool(forKey: "ollama.allowRemote") }
        set { UserDefaults.standard.set(newValue, forKey: "ollama.allowRemote") }
    }

    enum OllamaError: LocalizedError {
        case insecureEndpoint
        case remoteNotAllowed
        case modelNotInstalled(String)
        var errorDescription: String? {
            switch self {
            case .modelNotInstalled(let model):
                return "Ollama does not have the model “\(model)”. Run “ollama pull \(model)”, or set the Model in Settings → AI to a name that “ollama list” shows."
            case .insecureEndpoint:
                return "Ollama endpoint \(Ollama.baseURL) is neither local nor HTTPS. Your email content won't be sent over an unencrypted connection to a remote host — use http://127.0.0.1:11434 or an https:// URL."
            case .remoteNotAllowed:
                return "Ollama endpoint \(Ollama.baseURL) is not on this Mac. Enable “Allow remote Ollama” in Settings → AI if you intend to send mail content there over HTTPS."
            }
        }
    }

    /// Models the user switched off in Settings → AI. They stay installed in
    /// Ollama; they just stop appearing in MishMail's model pickers.
    static var disabledModels: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "ollama.disabledModels") ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: "ollama.disabledModels") }
    }

    /// All models installed in the local Ollama (GET /api/tags).
    static func installedModels() async throws -> [String] {
        let base = LLMEndpoint.trimmedBase(baseURL)
        guard let url = URL(string: "\(base)/api/tags") else { return [] }
        try validateEndpoint(url)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, _) = try await URLSession.shared.data(for: request)
        return LLMEndpoint.modelNames(fromJSONObject: try? JSONSerialization.jsonObject(with: data))
    }

    /// Installed models minus the ones the user disabled.
    static func enabledModels(installed: [String]) -> [String] {
        let disabled = disabledModels
        return installed.filter { !disabled.contains($0) }
    }

    /// Ollama answers a chat request for an uninstalled model with 404, which
    /// as a bare HTTP code reads like a wrong URL. Name the model instead.
    /// Returns nil for statuses this helper does not translate.
    static func chatFailure(status: Int, model: String) -> OllamaError? {
        status == 404 ? .modelNotInstalled(model) : nil
    }

    /// True when the configured endpoint is this machine.
    static var isLoopback: Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// Drops one model from Ollama's memory now. Best effort: a stopped Ollama
    /// or a refused endpoint is not an error the user needs to see.
    static func unload(model: String) async {
        let base = LLMEndpoint.trimmedBase(baseURL)
        guard !model.isEmpty, let url = URL(string: "\(base)/api/chat"),
              (try? validateEndpoint(url)) != nil,
              let body = try? OllamaChatWire.unloadBody(model: model) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2 // quit calls this; never block the app on it
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try? await URLSession.shared.data(for: request)
        await LoadedModels.shared.forget(model)
    }

    /// Unloads every model this session loaded, and forgets them.
    static func unloadAllLoadedByMishMail() async {
        for model in await LoadedModels.shared.takeAll() { await unload(model: model) }
    }

    /// Models MishMail asked Ollama to load in this session. Quit and
    /// model-switch unload exactly these, so a model another app loaded stays
    /// where it is.
    actor LoadedModels {
        static let shared = LoadedModels()
        private var models: Set<String> = []

        func note(_ model: String) { models.insert(model) }
        func forget(_ model: String) { models.remove(model) }
        func takeAll() -> Set<String> {
            let snapshot = models
            models.removeAll()
            return snapshot
        }
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
