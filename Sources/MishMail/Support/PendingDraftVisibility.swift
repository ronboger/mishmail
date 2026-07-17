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
}
