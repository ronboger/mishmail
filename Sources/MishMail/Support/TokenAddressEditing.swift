import Foundation

/// Pure rules for editing recipient chips in `TokenAddressField`.
///
/// Chips only used to be removable (×). Clicking the address should put it
/// back into the text field so the user can fix a typo without retyping.
enum TokenAddressEditing {
    /// Result of starting an edit: updated token list + the address loaded
    /// into the draft field.
    struct EditStart: Equatable {
        var tokens: [String]
        var draft: String
    }

    /// Commit pending draft text into a chip (blur, Return, trailing comma).
    /// Same clean/dedup rules as the pending-draft step of `beginEdit`, so the
    /// focus-loss path and the click-to-edit path cannot skew.
    static func commit(tokens: [String], draft: String) -> (tokens: [String], draft: String) {
        var next = tokens
        let cleaned = draft.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        if cleaned.contains("@"), !next.contains(cleaned) {
            next.append(cleaned)
        }
        return (next, "")
    }

    /// Start editing `token`:
    /// 1. Commit any pending draft that looks like an email (don't lose it).
    /// 2. Remove the first matching chip.
    /// 3. Put that address into the draft for inline editing.
    ///
    /// Incomplete draft text (no `@`) is discarded — the click is an explicit
    /// "edit this address" action and the chip value replaces the draft.
    ///
    /// Note: when the TextField loses focus before the chip button runs, the
    /// UI already called `commit`; this still works with `draft == ""`.
    static func beginEdit(tokens: [String], draft: String, token: String) -> EditStart {
        let committed = commit(tokens: tokens, draft: draft)
        var next = committed.tokens
        if let idx = next.firstIndex(of: token) {
            next.remove(at: idx)
        }
        return EditStart(tokens: next, draft: token)
    }

    /// Remove the first occurrence of `token` (× button). Prefer first-match
    /// over `removeAll` so duplicate addresses don't wipe every chip.
    static func remove(tokens: [String], token: String) -> [String] {
        var next = tokens
        if let idx = next.firstIndex(of: token) {
            next.remove(at: idx)
        }
        return next
    }
}
