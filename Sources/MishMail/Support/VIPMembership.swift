import Foundation

/// Pure VIP group membership helpers (no GRDB / UI).
///
/// Group names are case-sensitive and trimmed. Membership is multi-valued:
/// a sender can belong to zero or more groups. Active VIP status is true when
/// the sender has no groups, or when *any* of their groups is enabled.
enum VIPMembership {
    /// Trim, drop empties, de-dupe (first occurrence wins).
    static func normalizeGroups(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in raw {
            let name = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !seen.contains(name) else { continue }
            seen.insert(name)
            out.append(name)
        }
        return out
    }

    /// Merge `group` (single, optional) and `groups` (array, optional) into one
    /// ordered unique list. Empty inputs yield `[]` (caller may apply a default).
    static func resolveGroups(group: String?, groups: [String]?) -> [String] {
        var combined: [String] = []
        if let groups { combined.append(contentsOf: groups) }
        if let group { combined.append(group) }
        return normalizeGroups(combined)
    }

    /// Union existing membership with additional groups (order: existing first).
    static func union(existing: [String], adding: [String]) -> [String] {
        normalizeGroups(existing + adding)
    }

    /// Whether a VIP with the given group list is currently active.
    static func isActive(groups: [String], groupEnabled: [String: Bool]) -> Bool {
        let g = normalizeGroups(groups)
        if g.isEmpty { return true }
        return g.contains { groupEnabled[$0] ?? true }
    }

    /// Threads in `threads` with any VIP sender. A thread pins if *any*
    /// message's From is VIP (replying must not drop Priority).
    ///
    /// Reads the denormalized `thread.allFromEmails` (every distinct From
    /// address in the thread, lowercased — written by `deriveThreads` on
    /// every message-row write and backfilled by migration v23) rather than
    /// scanning `SELECT DISTINCT threadId, fromHeader FROM message WHERE
    /// threadId IN (…)` for every non-hit on every reload. Both sides
    /// normalize the same way: `MessageParser.emailAddress(from).lowercased()`.
    static func threadIds(in threads: [MailThread],
                          activeVIP: Set<String>) -> Set<String> {
        guard !activeVIP.isEmpty, !threads.isEmpty else { return [] }
        var hits = Set<String>()
        for t in threads {
            // Newest From first: the common hit, no string splitting.
            if !t.fromEmail.isEmpty, activeVIP.contains(t.fromEmail) {
                hits.insert(t.id)
                continue
            }
            for part in t.allFromEmails.split(separator: " ")
            where activeVIP.contains(String(part)) {
                hits.insert(t.id)
                break
            }
        }
        return hits
    }
}
