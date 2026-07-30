import Foundation

/// Pure helpers for Gmail `threadId` on send / draft create.
///
/// Local rows store composite ids (`"<accountEmail>:<gmailThreadId>"`). The
/// Gmail API wants only the bare gmail thread id, and only when that thread
/// actually exists in the mailbox we call. Passing a foreign or gone thread
/// id surfaces as `Gmail API error 404` on `messages.send` / `drafts.create`.
enum SendThreading {

    /// Bare Gmail thread id to pass on send/draft, or `nil` to let Gmail
    /// start (or attach via headers only) a new conversation.
    ///
    /// - Rejects empty / whitespace values.
    /// - Requires the local composite to be owned by `apiAccountId` so a
    ///   send-as / multi-account mismatch never ships a foreign threadId.
    /// - Accepts a bare id only when it has no `:` (legacy / already-extracted).
    static func apiThreadId(localThreadId: String?, apiAccountId: String) -> String? {
        guard let raw = localThreadId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let account = apiAccountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty else { return nil }

        let prefix = account + ":"
        if raw.lowercased().hasPrefix(prefix.lowercased()) {
            let bare = String(raw.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return bare.isEmpty ? nil : bare
        }
        // No account prefix: treat as already-bare only when it doesn't look
        // like someone else's composite (`other@x.com:hex`).
        if raw.contains(":") { return nil }
        return raw
    }

    /// Prefer the reply parent thread; otherwise the draft's. Forwards pass
    /// a nil reply id so only the draft (if any) can supply a thread.
    static func localThreadId(replyThreadId: String?, draftThreadId: String?) -> String? {
        replyThreadId ?? draftThreadId
    }

    /// True when `error` is a Gmail HTTP 404 — thread (or other resource) gone.
    /// Safe signal to retry send/draft **without** a threadId so the user's
    /// mail still goes out / saves as a fresh conversation.
    static func isNotFound(_ error: Error) -> Bool {
        if let g = error as? GmailError, case .http(let code, _) = g, code == 404 {
            return true
        }
        return false
    }
}
