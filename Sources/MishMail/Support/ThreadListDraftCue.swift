import Foundation

/// Orange "Draft" prefix on thread-list participant rows (Gmail/Notion style).
///
/// Must key off denorm `inDrafts` (live DRAFT without TRASH), **not** the
/// historical `labelIds` union. Discarded compose attempts stay as
/// `DRAFT TRASH` on individual messages and keep `DRAFT` in the union forever
/// (Fund Expense / Anna) — those must not paint the list cue.
enum ThreadListDraftCue {
    enum Style: Equatable {
        /// No orange marker.
        case none
        /// Draft-only thread (or empty names): just "Draft".
        case draftOnly
        /// Live draft in a multi-message thread: "Draft, me .. Anna".
        case draftLeadingNames
    }

    static func showsMarker(
        inDrafts: Bool,
        messageCount: Int,
        participants: String
    ) -> Style {
        guard inDrafts else { return .none }
        if messageCount <= 1 || participants.isEmpty { return .draftOnly }
        return .draftLeadingNames
    }
}
