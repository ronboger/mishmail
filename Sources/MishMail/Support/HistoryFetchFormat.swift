import Foundation

/// Decides Gmail `getMessage` format for history-driven fetches.
///
/// - `messagesAdded`: always `full` (new payload, need bodies/snippet).
/// - Local message missing: `full` (must create a coherent row).
/// - Label-only change on a message we already have: no fetch (caller patches
///   labelIds locally) — this helper is only for when a network get is needed.
/// - Local exists but we still need a get (e.g. labelIds absent from history
///   event and local row incomplete): prefer `metadata` when body is not required.
enum HistoryFetchFormat {
    enum Reason: Equatable {
        case messagesAdded
        case localMissing
        case labelOnlyNeedsMetadata
        case needsFullBody
    }

    enum Decision: Equatable {
        case full(Reason)
        case metadata(Reason)
        /// Caller should not call getMessage at all.
        case skip
    }

    /// - `isMessagesAdded`: history entry is messagesAdded.
    /// - `localExists`: message row already in cache.
    /// - `historyHasLabelIds`: history event carried label id lists.
    /// - `needBody`: caller must hydrate body (e.g. user opened the thread).
    static func decide(
        isMessagesAdded: Bool,
        localExists: Bool,
        historyHasLabelIds: Bool,
        needBody: Bool
    ) -> Decision {
        if isMessagesAdded { return .full(.messagesAdded) }
        if !localExists { return .full(.localMissing) }
        if needBody { return .full(.needsFullBody) }
        // Local row exists; label-only coherence can use metadata (headers +
        // labelIds) without downloading the body payload.
        if historyHasLabelIds { return .skip } // pure local label patch path
        return .metadata(.labelOnlyNeedsMetadata)
    }

    static func formatString(_ decision: Decision) -> String? {
        switch decision {
        case .full: return "full"
        case .metadata: return "metadata"
        case .skip: return nil
        }
    }
}
