import Foundation

/// Policy for auto mark-as-read when a conversation is opened in the reading pane.
///
/// Immediate mark-on-select is too aggressive: j/k or click-scroll through the
/// inbox would clear the unread badge on every pass. We dwell first; leaving
/// the thread (or cancelling the open task) aborts. Explicit actions like
/// archive (`e`) mark read immediately on the store path instead.
enum MarkReadOnOpen {
    /// How long the reading pane must stay on a thread before auto mark-read.
    static let dwellNanoseconds: UInt64 = 1_000_000_000  // 1s

    /// After the dwell completes, decide whether to call `setRead`.
    ///
    /// - Parameters:
    ///   - selectedId: current `selectedThreadId` (must still be this thread)
    ///   - threadId: the thread the open task was started for
    ///   - isUnread: latest unread flag for that thread (prefer live store state)
    static func shouldMarkRead(selectedId: String?, threadId: String,
                               isUnread: Bool) -> Bool {
        selectedId == threadId && isUnread
    }
}
