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
    ///
    /// The draft can hold a whole pasted list; each mailbox becomes its own
    /// chip (`splitRecipients`). Dedup is by address, so the same mailbox in
    /// another case or with a display name is not a second recipient.
    static func commit(tokens: [String], draft: String) -> (tokens: [String], draft: String) {
        var next = tokens
        var seen = Set(tokens.map(addressKey))
        for part in splitRecipients(draft) where seen.insert(addressKey(part)).inserted {
            next.append(part)
        }
        return (next, "")
    }

    // MARK: - Recipient lists

    /// Where a scan of recipient text stands: inside a quoted string, an
    /// angle address or a comment, a `,` `;` or newline is sender text, not
    /// a separator.
    private struct ListScan {
        var inQuote = false
        var escaped = false
        var angleDepth = 0
        var parenDepth = 0

        var atTopLevel: Bool { !inQuote && angleDepth == 0 && parenDepth == 0 }

        /// Feeds one character. True when it is a top-level separator.
        mutating func isSeparator(_ ch: Character) -> Bool {
            if inQuote {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inQuote = false }
                return false
            }
            switch ch {
            case "\"": inQuote = true
            case "<": angleDepth += 1
            case ">": angleDepth = max(0, angleDepth - 1)
            case "(": parenDepth += 1
            case ")": parenDepth = max(0, parenDepth - 1)
            case ",", ";": return atTopLevel
            default: return ch.isNewline && atTopLevel
            }
            return false
        }
    }

    private static let listTrim = CharacterSet(charactersIn: ",;").union(.whitespacesAndNewlines)

    /// Splits pasted or typed recipient text into one string per mailbox.
    ///
    /// Separators are `,` `;` and newlines outside quoted strings, angle
    /// addresses and comments. A run of bare addresses separated only by
    /// spaces or tabs (a pasted column) is split too; a display name never
    /// is. Pieces without an address are dropped. A single mailbox comes
    /// back unchanged.
    static func splitRecipients(_ text: String) -> [String] {
        var scan = ListScan()
        var pieces: [String] = []
        var current = ""
        for ch in text {
            if scan.isSeparator(ch) {
                pieces.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        // An unterminated quote: nothing after it can be split with
        // confidence, so the whole text stays one mailbox.
        if scan.inQuote {
            let whole = text.trimmingCharacters(in: listTrim)
            return whole.contains("@") ? [whole] : []
        }
        pieces.append(current)

        var out: [String] = []
        for piece in pieces {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.contains("@") else { continue }
            let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            if words.count > 1, words.allSatisfy(isBareAddress) {
                out.append(contentsOf: words)
            } else {
                out.append(trimmed)
            }
        }
        return out
    }

    /// `local@domain` with no name, quotes, brackets or comment.
    private static func isBareAddress(_ word: String) -> Bool {
        let parts = word.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        return !word.contains(where: { "<>\"(),;".contains($0) })
    }

    /// Lowercased bare address of a mailbox: the identity used for dedup.
    static func addressKey(_ mailbox: String) -> String {
        MessageParser.emailAddress(mailbox).lowercased()
    }

    /// True when the draft's last character is a `,` or `;` that ends a
    /// mailbox. Inside a quoted name or an angle address it is ordinary
    /// text: typing `"Boger, Ron" <r@x.com>` must not commit at the comma.
    static func shouldCommitOnSeparator(_ draft: String) -> Bool {
        guard let last = draft.last, last == "," || last == ";" else { return false }
        var scan = ListScan()
        var lastIsSeparator = false
        for ch in draft { lastIsSeparator = scan.isSeparator(ch) }
        return lastIsSeparator
    }

    /// Recipient state a draft save should use.
    ///
    /// `committing: false` is the silent autosave: it runs on a timer while
    /// the user may be mid-address, so it saves the chips only and returns
    /// the inputs untouched — committing would chip a half-typed
    /// `bob@exam`, and clearing would erase what is being typed.
    /// `committing: true` is the close path (Esc / ✕ / replaced card), where
    /// a typed address counts as a recipient, same as `commit`.
    static func persistSnapshot(tokens: [String], draft: String,
                                committing: Bool) -> (tokens: [String], draft: String) {
        committing ? commit(tokens: tokens, draft: draft) : (tokens, draft)
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

    /// Gmail-style Backspace:
    /// - selection present → delete selected chips (draft text ignored)
    /// - no selection + empty draft → select the last chip (do not delete yet)
    /// - no selection + non-empty draft → ignore (field editor owns the key)
    ///
    /// `allowSelect` is false for forward-delete (keyCode 117): Gmail only
    /// removes an existing selection and never starts one from forward-delete.
    static func handleBackspace(
        tokens: [String],
        draftIsEmpty: Bool,
        selection: ChipSelection?,
        allowSelect: Bool = true
    ) -> BackspaceOutcome {
        guard !tokens.isEmpty else { return .ignore }
        if let selection {
            let next = removeSelected(tokens: tokens, selection: selection)
            return .remove(tokens: next, selection: nil)
        }
        guard allowSelect, draftIsEmpty else { return .ignore }
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
    /// brackets, semicolon/colon/at that confuse address parsers, or
    /// leading/trailing whitespace).
    static func needsDisplayNameQuotes(_ name: String) -> Bool {
        name.contains(where: { ",\"<>();:@".contains($0) })
            || name.first?.isWhitespace == true
            || name.last?.isWhitespace == true
    }
}
