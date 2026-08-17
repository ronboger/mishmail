import Foundation

/// Resolves the configured provider for a task and adapts the shared client
/// stream to the text-only stream needed by one-shot app features.
@MainActor
enum LLMTaskRunner {
    struct Resolved {
        var config: LLMProviderConfig
        var model: String
    }

    static func resolve(_ task: LLMTask) -> Resolved? {
        let assignment = LLMProviderStore.assignment(for: task)
        let providers = LLMProviderStore.load()
        guard let config = providers.first(where: { $0.id == assignment.providerID }) else {
            let fallback = LLMProviderStore.builtInOllama()
            return Resolved(config: fallback, model: fallback.defaultModel)
        }
        return Resolved(config: config, model: assignment.model)
    }

    static func errorMessage(_ error: Error, task: LLMTask) -> String {
        if let llmError = error as? LLMClientError,
           case .missingCredential = llmError {
            let taskName: String
            switch task {
            case .drafts: taskName = "drafts"
            case .summaries: taskName = "summaries"
            case .triage: taskName = "triage"
            case .askMish: taskName = "Ask Mish"
            }
            return "No model configured for \(taskName). Check Settings → AI."
        }
        if let urlError = error as? URLError,
           [.cannotConnectToHost, .networkConnectionLost, .timedOut].contains(urlError.code),
           let resolved = resolve(task), resolved.config.kind == .ollama {
            return "Couldn't reach Ollama at \(Ollama.baseURL). Install it from ollama.com and run: ollama pull \(resolved.model)."
        }
        return error.localizedDescription
    }

    /// `maxOutputTokens` overrides the task's default Ollama output cap for
    /// this one request: nil keeps the per-task default, 0 lifts the cap.
    /// Quick-reply suggestions share the triage task assignment but must not
    /// inherit triage's one-word 32-token cap.
    static func stream(task: LLMTask, prompt: String,
                       maxOutputTokens: Int? = nil) -> AsyncThrowingStream<String, Error> {
        guard let resolved = resolve(task) else {
            return AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }

        return AsyncThrowingStream { continuation in
            let innerTask = Task {
                do {
                    for try await event in await LLMClient.shared.stream(
                        messages: [LLMMessage(role: .user, text: prompt)],
                        tools: [], config: resolved.config, model: resolved.model,
                        task: task, maxOutputTokens: maxOutputTokens) {
                        switch event {
                        case .token(let text):
                            continuation.yield(text)
                        case .toolCall, .reasoning:
                            break
                        case .done(_, let usage):
                            if let usage {
                                let row = LLMUsageLog.row(task: task, config: resolved.config,
                                                          model: resolved.model, usage: usage,
                                                          now: Date())
                                try? await AppDatabase.shared.dbPool.write { db in
                                    try row.insert(db)
                                }
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in innerTask.cancel() }
        }
    }

    static func generate(task: LLMTask, prompt: String) async throws -> String {
        var output = ""
        for try await token in stream(task: task, prompt: prompt) {
            output += token
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
