import Foundation

/// Pure rules for editing recipient chips in `TokenAddressField`.
///
/// Chips only used to be removable (×). Clicking the address should put it
/// back into the text field so the user can fix a typo without retyping.
///
/// Keyboard selection mirrors Gmail / Superhuman:
/// - Empty draft + Backspace (or ←) first **selects** the last chip.
/// - Backspace with a selection **removes** the selected chips.
/// - Shift+← / Shift+→ extends the selection range.
/// - Cmd+C copies `Name <email>` (comma-joined when multi-selected).
enum TokenAddressEditing {
    /// Result of starting an edit: updated token list + the address loaded
    /// into the draft field.
    struct EditStart: Equatable {
        var tokens: [String]
        var draft: String
    }

    /// Inclusive chip selection (anchor = where it started, focus = keyboard end).
    /// Matches Gmail’s range-select semantics under Shift+arrow.
    struct ChipSelection: Equatable {
        var anchor: Int
        var focus: Int

        var range: ClosedRange<Int> {
            min(anchor, focus)...max(anchor, focus)
        }

        func contains(_ index: Int) -> Bool { range.contains(index) }

        static func single(_ index: Int) -> ChipSelection {
            ChipSelection(anchor: index, focus: index)
        }
    }

    enum HorizontalDirection: Equatable {
        case left
        case right

        var delta: Int { self == .left ? -1 : 1 }
    }

    /// Outcome of Backspace / forward-delete while the draft is empty.
    enum BackspaceOutcome: Equatable {
        case ignore
        case select(ChipSelection)
        case remove(tokens: [String], selection: ChipSelection?)
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

    /// Remove every chip in `selection.range` (high → low so indices stay valid).
    static func removeSelected(tokens: [String], selection: ChipSelection) -> [String] {
        var next = tokens
        for i in selection.range.reversed() where next.indices.contains(i) {
            next.remove(at: i)
        }
        return next
    }

    /// Gmail-style Backspace when the draft is empty:
    /// - no selection → select the last chip (do not delete yet)
    /// - selection → delete selected chips and clear selection
    static func handleBackspace(
        tokens: [String],
        draftIsEmpty: Bool,
        selection: ChipSelection?
    ) -> BackspaceOutcome {
        guard draftIsEmpty, !tokens.isEmpty else { return .ignore }
        if let selection {
            let next = removeSelected(tokens: tokens, selection: selection)
            return .remove(tokens: next, selection: nil)
        }
        return .select(.single(tokens.count - 1))
    }

    /// Move or extend chip selection with ← / → (and Shift variants).
    ///
    /// - No selection + empty draft + left → select last chip.
    /// - No selection + empty draft + right → no-op (cursor stays in draft).
    /// - With selection, left/right moves focus; `extend` keeps the anchor.
    /// - Right past the last chip without extend clears selection (return to draft).
    /// - Left past the first chip clamps to 0.
    static func moveSelection(
        tokens: [String],
        selection: ChipSelection?,
        direction: HorizontalDirection,
        extend: Bool,
        draftIsEmpty: Bool
    ) -> ChipSelection? {
        guard !tokens.isEmpty else { return nil }

        if let selection {
            let nextFocus = selection.focus + direction.delta
            if !tokens.indices.contains(nextFocus) {
                if direction == .right, !extend {
                    return nil
                }
                return selection
            }
            if extend {
                return ChipSelection(anchor: selection.anchor, focus: nextFocus)
            }
            return .single(nextFocus)
        }

        guard draftIsEmpty, direction == .left else { return nil }
        return .single(tokens.count - 1)
    }

    /// Clamp / drop a selection after the token list changes length.
    static func clampedSelection(_ selection: ChipSelection?, tokenCount: Int) -> ChipSelection? {
        guard let selection, tokenCount > 0 else { return nil }
        let maxIdx = tokenCount - 1
        let anchor = min(max(selection.anchor, 0), maxIdx)
        let focus = min(max(selection.focus, 0), maxIdx)
        return ChipSelection(anchor: anchor, focus: focus)
    }

    /// Clipboard string for selected emails — Gmail / Superhuman form:
    /// `Josh Yang <josh@glyphic.bio>`, bare email when no usable name,
    /// comma-space joined for multiple.
    static func clipboardText(
        emails: [String],
        nameForEmail: (String) -> String?
    ) -> String {
        emails.map { formatMailbox(email: $0, name: nameForEmail($0)) }
            .joined(separator: ", ")
    }

    /// Single mailbox for the clipboard / paste targets.
    static func formatMailbox(email: String, name: String?) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare(email) != .orderedSame else {
            return email
        }
        if needsDisplayNameQuotes(trimmed) {
            let escaped = trimmed
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\" <\(email)>"
        }
        return "\(trimmed) <\(email)>"
    }

    /// True when the display name must be RFC-quoted (comma, quotes, angle
    /// brackets, or leading/trailing specials that confuse address parsers).
    static func needsDisplayNameQuotes(_ name: String) -> Bool {
        name.contains(where: { ",\"<>()".contains($0) })
            || name.first?.isWhitespace == true
            || name.last?.isWhitespace == true
    }
}
