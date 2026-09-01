import Foundation

/// Pure keyboard rules for the compose From identity control. Kept free of
/// SwiftUI so the arrow / type-ahead behaviour is unit tested.
///
/// Closed control: ↑/↓ (and ←/→) step the selection directly, wrapping at
/// the ends — like an NSPopUpButton without opening it. Open list: the same
/// keys move a highlight, Return/Space commit it, Esc closes.
enum FromPickerModel {
    /// Index reached by moving `delta` rows from `current`, wrapping around.
    /// A missing `current` (no selection yet) starts from the first / last row.
    static func step(from current: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current, count > 1 else {
            return delta >= 0 ? 0 : count - 1
        }
        let next = (current + delta) % count
        return next < 0 ? next + count : next
    }

    /// Type-ahead: first row after `current` whose email or display name
    /// starts with `prefix` (case-insensitive), wrapping. `nil` when none.
    static func match(prefix: String, in identities: [SendIdentity],
                      after current: Int?) -> Int? {
        let needle = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty, !identities.isEmpty else { return nil }
        let start = ((current ?? -1) + 1) % identities.count
        for offset in 0..<identities.count {
            let index = (start + offset) % identities.count
            let identity = identities[index]
            if identity.email.lowercased().hasPrefix(needle)
                || identity.displayName.lowercased().hasPrefix(needle) {
                return index
            }
        }
        return nil
    }

    /// Second line for a list row: the display name when it adds information,
    /// plus "via <mailbox>" when the address is sent through another account.
    static func detail(for identity: SendIdentity) -> String {
        var parts: [String] = []
        let name = identity.displayName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, name.caseInsensitiveCompare(identity.email) != .orderedSame {
            parts.append(name)
        }
        if identity.email.caseInsensitiveCompare(identity.accountId) != .orderedSame {
            parts.append("via \(identity.accountId)")
        }
        return parts.joined(separator: " · ")
    }
}
