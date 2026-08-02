import Foundation

/// Gmail's mark-read / mark-unread chords: **Shift+I** and **Shift+U**.
///
/// These are fixed (not rebindable). `KeyBindings` only owns single keys
/// without modifiers; the app's `u` toggle remains a separate, rebindable
/// command. ContentView consults this before the single-key registry so a
/// held Shift is not lowercased into a no-op (or a wrong command).
///
/// Shift+I is state-aware: Gmail's chord marks read, but when every target is
/// already read, Shift+I marks unread so the chord always changes state
/// (read → unread). Shift+U always marks unread.
enum GmailMarkReadKeys {
    enum Chord: Equatable {
        /// Shift+I — mark read, or mark unread when already fully read.
        case shiftI
        /// Shift+U — always mark unread.
        case shiftU
    }

    /// - Parameters:
    ///   - key: `NSEvent.charactersIgnoringModifiers` (Shift still affects
    ///     letters, so callers may pass `"I"` / `"U"`).
    ///   - shiftOnly: Shift held, and no ⌘ / ⌥ / ⌃.
    static func chord(key: String, shiftOnly: Bool) -> Chord? {
        guard shiftOnly, key.count == 1 else { return nil }
        switch key.lowercased() {
        case "i": return .shiftI
        case "u": return .shiftU
        default: return nil
        }
    }

    /// Desired `read` flag for `setRead` given the chord and whether any
    /// target thread is currently unread.
    ///
    /// - Shift+I: if any target is unread → mark all read; if all are already
    ///   read → mark all unread.
    /// - Shift+U: always mark unread.
    static func desiredRead(chord: Chord, anyUnread: Bool) -> Bool {
        switch chord {
        case .shiftI: return anyUnread
        case .shiftU: return false
        }
    }

    /// - Parameters:
    ///   - key: `NSEvent.charactersIgnoringModifiers` (Shift still affects
    ///     letters, so callers may pass `"I"` / `"U"`).
    ///   - shiftOnly: Shift held, and no ⌘ / ⌥ / ⌃.
    /// - Returns: `true` = mark read intent for Shift+I, `false` = mark unread
    ///   for Shift+U, `nil` = not this chord.
    ///
    /// Prefer `chord` + `desiredRead` at call sites so Shift+I can flip a
    /// fully-read selection to unread. Kept for simple chord tests.
    static func markAsRead(key: String, shiftOnly: Bool) -> Bool? {
        switch chord(key: key, shiftOnly: shiftOnly) {
        case .shiftI: return true
        case .shiftU: return false
        case nil: return nil
        }
    }
}
