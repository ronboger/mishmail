import Foundation

/// Splits a thread list into the pinned Priority section and everything
/// else, preserving the incoming (date-sorted) order. What qualifies is a
/// user choice: VIP senders only, starred only (a tight, hand-picked
/// section), or starred plus Gmail's IMPORTANT label (Gmail's own priority
/// prediction — broader). No local AI either way.
enum PrioritySplit {
    enum Mode: String, CaseIterable {
        case off
        case vips
        case starred
        case starredImportant

        var title: String {
            switch self {
            case .off: return "Off — chronological"
            case .vips: return "VIPs only"
            case .starred: return "Starred"
            case .starredImportant: return "Starred + Important"
            }
        }
    }

    static func qualifies(_ thread: MailThread, mode: Mode,
                          vipThreadIds: Set<String> = [],
                          vipAlwaysPins: Bool = true) -> Bool {
        let isVIP = vipThreadIds.contains(thread.id)
        switch mode {
        case .off: return false
        case .vips:
            return isVIP
        case .starred:
            return thread.isStarred || (vipAlwaysPins && isVIP)
        case .starredImportant:
            return thread.isStarred || thread.labels.contains("IMPORTANT")
                || (vipAlwaysPins && isVIP)
        }
    }

    static func partition(_ threads: [MailThread], mode: Mode,
                          vipThreadIds: Set<String> = [],
                          vipAlwaysPins: Bool = true) -> (priority: [MailThread], rest: [MailThread]) {
        guard mode != .off else { return ([], threads) }
        var priority: [MailThread] = []
        var rest: [MailThread] = []
        for thread in threads {
            if qualifies(thread, mode: mode, vipThreadIds: vipThreadIds,
                         vipAlwaysPins: vipAlwaysPins) {
                priority.append(thread)
            } else {
                rest.append(thread)
            }
        }
        return (priority, rest)
    }

    /// Pulls every plausible email address out of free-form text — comma or
    /// newline separated lists, "Name <email>" forms, pasted CSV columns.
    /// Lowercased, deduped, original order preserved.
    static func parseEmails(_ text: String) -> [String] {
        let pattern = #"[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var out: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range, in: text) else { continue }
            let email = text[r].lowercased()
            if seen.insert(email).inserted { out.append(email) }
        }
        return out
    }
}
