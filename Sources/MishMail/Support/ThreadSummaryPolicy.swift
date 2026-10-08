import CryptoKit
import Foundation

enum ThreadSummaryPolicy {
    static let autoSummarizeKey = "ai.autoSummarizeLocalThreads"

    static func sentMessages(_ messages: [Message]) -> [Message] {
        messages.filter { !ForwardComposer.hasDraftLabel($0.labelIds) }
            .sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }

    /// Gmail sent-message bodies are immutable per id. Header fingerprints
    /// therefore survive hydration, CID inlining, and read/label changes.
    /// Draft edits cannot make a conversation summary stale.
    static func fingerprint(subject: String, messages: [Message]) -> String {
        let sent = sentMessages(messages)
        guard !sent.isEmpty else { return "" }
        let fields = [subject] + sent.flatMap {
            [$0.id, $0.subject, $0.fromHeader, $0.toHeader, $0.ccHeader,
             String($0.date.timeIntervalSince1970), $0.snippet]
        }
        let framed = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isWorthSummarizing(_ messages: [Message]) -> Bool {
        let sent = sentMessages(messages)
        return sent.count >= 2 || sent.contains {
            $0.bodyText.count > 800 || ($0.bodyHTML?.count ?? 0) > 2_000
        }
    }

    /// An opt-in convenience on open, restricted to Ollama on this Mac.
    /// A hosted or LAN assignment must never silently receive a thread.
    static func shouldAutoSummarize(messages: [Message], config: LLMProviderConfig?,
                                    model: String? = nil, enabled: Bool) -> Bool {
        guard enabled, let config, config.kind == .ollama,
              !LLMRemotePolicy.sendsMailOffDevice(config),
              !LLMRemotePolicy.isOllamaCloudModel(model ?? config.defaultModel) else { return false }
        let sent = sentMessages(messages)
        return sent.count >= 3 || sent.contains {
            $0.bodyText.count > 1_600 || ($0.bodyHTML?.count ?? 0) > 4_000
        }
    }

    static func isCurrent(_ row: ThreadSummaryRow, fingerprint: String) -> Bool {
        !fingerprint.isEmpty && row.contentFingerprint == fingerprint
    }
}
