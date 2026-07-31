import Foundation

/// Hides the in-thread draft affordances for the draft that is *currently open
/// in a compose editor*, so Continue doesn't leave the orange card sitting
/// under (or over) an editor holding the same content.
///
/// Deliberately separate from `PendingDraftVisibility`, which is undo-send only
/// and filters the payload itself. This one is render-time and reversible: the
/// card returns the moment compose closes, and Discard from the card still
/// works whenever the card is visible.
///
/// Autosave moves a draft to a new Gmail message id (`replacingDraft` chain),
/// so the caller registers every id the open compose has owned — matching only
/// the id compose opened on would let the card reappear after the first save.
enum ComposingDraftVisibility {
    /// The draft card for `messageId` is hidden while compose owns that id.
    static func hidesDraftCard(messageId: String,
                               composingDraftIds: Set<String>) -> Bool {
        composingDraftIds.contains(messageId)
    }

    /// Slim long-thread banner: only for a live draft that is *not* already
    /// open in compose, and only when the card is likely below the first
    /// viewport (≥4 messages).
    static func showsDraftBanner(liveDraftIds: [String],
                                 messageCount: Int,
                                 composingDraftIds: Set<String>) -> Bool {
        guard messageCount > 3 else { return false }
        return liveDraftIds.contains { !composingDraftIds.contains($0) }
    }
}
