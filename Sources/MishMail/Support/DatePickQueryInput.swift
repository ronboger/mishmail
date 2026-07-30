import Foundation

/// Pure keystroke → filter-query mapping for `DatePickSheet`.
///
/// When the overlay opens, the text field can lose the focus race against the
/// thread list. ContentView stands down while snooze is open, so unclaimed
/// keys fall through to List type-select (typing `s` jumps to an email). The
/// sheet's local monitor uses this helper to claim typing keys until the field
/// is first responder — same idea as LabelPicker's ContentView routing.
enum DatePickQueryInput {
    enum Outcome: Equatable {
        /// Event claimed; use the new query (may be unchanged, e.g. delete on empty).
        case consume(String)
        /// Not typed into the query (control/function keys, empty payload).
        /// The sheet monitor still swallows bare unmodified keys while
        /// unfocused so List type-select cannot steal them.
        case passThrough
    }

    /// Delete (keyCode 51) or insertable characters only. Caller must already
    /// know the text field is not editing (`TextFocus.isEditing` false).
    static func handle(query: String, keyCode: UInt16, characters: String?) -> Outcome {
        if keyCode == 51 {  // delete / backspace
            if query.isEmpty { return .consume(query) }
            return .consume(String(query.dropLast()))
        }
        guard let characters, !characters.isEmpty,
              !characters.unicodeScalars.contains(where: { isNonTypingScalar($0) })
        else { return .passThrough }
        return .consume(query + characters)
    }

    /// Control chars (Cc) and Apple private-use function-key glyphs
    /// (U+F700…F8FF: left/right arrows, Home/End, F-keys, …). Those arrive in
    /// `charactersIgnoringModifiers` but must never enter the date query —
    /// otherwise an unfocused left-arrow silently breaks matching with no
    /// visible cue.
    private static func isNonTypingScalar(_ scalar: Unicode.Scalar) -> Bool {
        if CharacterSet.controlCharacters.contains(scalar) { return true }
        return (0xF700...0xF8FF).contains(scalar.value)
    }
}
