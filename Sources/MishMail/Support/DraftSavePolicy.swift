import Foundation

/// What `MailStore.persistDraft` does with a draft that Gmail did not take.
/// Pure so the rule is unit-tested; `OfflinePolicy` owns the connectivity
/// side, this type adds the close-path rule on top of it.
enum DraftSavePolicy {
    /// Whether the draft must be written to the Outbox (`LocalDraft`).
    ///
    /// - Connectivity failure: always (autosave and close) — the offline path.
    /// - Any other failure (re-authorization, 429, 5xx, a rejected header):
    ///   only when `closing`. The card is about to unmount and is the last
    ///   holder of the text; dropping it there loses the message. During
    ///   autosave the card still holds the text and shows "Draft not saved".
    static func keepsDraftLocally(error: Error, closing: Bool) -> Bool {
        closing || OfflinePolicy.shouldDefer(error)
    }

    /// A kept draft flips the app to offline only for a connectivity failure.
    /// A rejection arrives over a working network.
    static func marksOffline(_ error: Error) -> Bool {
        OfflinePolicy.shouldDefer(error)
    }

    /// Banner for a close-path save that Gmail rejected and the Outbox kept.
    /// Replaces "Draft not saved: …", which is no longer true.
    static func keptAfterRejectionMessage(_ error: Error) -> String {
        "Gmail didn't accept the draft — kept in the Outbox: \(error.localizedDescription)"
    }
}
