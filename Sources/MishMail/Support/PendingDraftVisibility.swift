import Foundation

/// Keeps the Gmail draft intact during Undo Send while hiding its stale local
/// representation from MishMail's thread and draft affordances.
enum PendingDraftVisibility {
    static func visibleMessages(
        _ messages: [Message],
        suppressing ids: Set<String>
    ) -> [Message] {
        guard !ids.isEmpty else { return messages }
        return messages.filter { !ids.contains($0.id) }
    }

    /// A Drafts-folder thread row disappears only if it contains drafts and
    /// every draft is currently suppressed by pending send.
    static func suppressesThread(
        draftMessageIds: [String],
        suppressing ids: Set<String>
    ) -> Bool {
        !draftMessageIds.isEmpty && draftMessageIds.allSatisfy(ids.contains)
    }
}
