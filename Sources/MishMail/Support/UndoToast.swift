import Foundation

/// Timing and presentation rules for the bottom undo capsule (archive, trash,
/// spam, snooze, …). Undo-send uses `MailStore.undoSendWindow` instead — that
/// duration is the actual send delay, not just UI chrome.
enum UndoToast {
    /// How long the toast stays on screen after archive/trash/etc.
    /// Short enough that keyboard triage doesn't leave a lingering capsule;
    /// long enough to catch a mis-press with `z` / ⌘Z.
    static let displayDuration: TimeInterval = 3.5

    /// Animate enter/exit on presence only. Driving animation off
    /// `UndoAction.id` re-slides the capsule on every replacement, which
    /// makes rapid keyboard archive/trash feel stuck on the toast.
    static func isPresented(_ action: Any?) -> Bool {
        action != nil
    }
}
