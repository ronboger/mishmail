import Foundation

/// Gmail's mark-read / mark-unread chords: **Shift+I** and **Shift+U**.
///
/// These are fixed (not rebindable). `KeyBindings` only owns single keys
/// without modifiers; the app's `u` toggle remains a separate, rebindable
/// command. ContentView consults this before the single-key registry so a
/// held Shift is not lowercased into a no-op (or a wrong command).
enum GmailMarkReadKeys {
    /// - Parameters:
    ///   - key: `NSEvent.charactersIgnoringModifiers` (Shift still affects
    ///     letters, so callers may pass `"I"` / `"U"`).
    ///   - shiftOnly: Shift held, and no ⌘ / ⌥ / ⌃.
    /// - Returns: `true` = mark read, `false` = mark unread, `nil` = not this chord.
    static func markAsRead(key: String, shiftOnly: Bool) -> Bool? {
        guard shiftOnly, key.count == 1 else { return nil }
        switch key.lowercased() {
        case "i": return true
        case "u": return false
        default: return nil
        }
    }
}
