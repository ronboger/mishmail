import Foundation

/// Decides Gmail `getMessage` format for history-driven fetches.
///
/// Used by `SyncEngine.incrementalSync` when classifying `fullFetch` ids:
/// - `messagesAdded` / local missing: always `full` (new payload, need bodies).
/// - Local exists but still fetched (edge cases): prefer `metadata` when body
///   is not required.
/// - Label-only change on a cached message: `skip` — caller patches labelIds
///   locally (those ids never enter fullFetch after the label-ops pass).
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
