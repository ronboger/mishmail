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

    /// Cutoff for the Priority recency window. `days <= 0` means no window
    /// (all starred / IMPORTANT qualify by mode alone).
    static func cutoff(days: Int, now: Date = Date()) -> Date? {
        guard days > 0 else { return nil }
        return now.addingTimeInterval(-TimeInterval(days) * 86_400)
    }

    /// Normalize a stored max-count setting: `nil` or `<= 0` means no cap.
    static func cap(_ raw: Int) -> Int? {
        raw > 0 ? raw : nil
    }

    /// - Parameter hiddenCategories: effective category-hide set (CATEGORY_* ids).
    ///   Manually starred threads always hoist into Priority regardless of this
    ///   set. Only the IMPORTANT-only hoist (`.starredImportant` mode, not
    ///   starred) is suppressed when the thread sits in a hidden category —
    ///   those threads still pin through `CategoryHide` chronologically.
    ///   VIP pins are unaffected — VIPs are people.
    /// - Parameter newerThan: when non-nil, star / IMPORTANT qualification also
    ///   requires `thread.lastDate >= newerThan`. VIP pins via `vipAlwaysPins`
    ///   ignore the window. `.off` and `.vips` ignore it entirely.
    /// - Parameter maxCount: when non-nil and `> 0`, at most that many
    ///   non-VIP-exempt threads enter Priority (newest first; input is
    ///   date-sorted). VIP pins via `vipAlwaysPins` never consume the cap
    ///   and may push the section past `maxCount` — VIPs are people.
    ///   `qualifies` itself is cap-agnostic; the limit is applied only here.
    static func qualifies(_ thread: MailThread, mode: Mode,
                          vipThreadIds: Set<String> = [],
                          vipAlwaysPins: Bool = true,
                          hiddenCategories: Set<String> = [],
                          newerThan: Date? = nil) -> Bool {
        let isVIP = vipThreadIds.contains(thread.id)
        switch mode {
        case .off: return false
        case .vips:
            return isVIP
        case .starred:
            if vipAlwaysPins && isVIP { return true }
            guard thread.isStarred else { return false }
            return isWithinWindow(thread, newerThan: newerThan)
        case .starredImportant:
            if vipAlwaysPins && isVIP { return true }
            if thread.isStarred {
                return isWithinWindow(thread, newerThan: newerThan)
            }
            guard thread.labels.contains("IMPORTANT") else { return false }
            guard !isInHiddenCategory(thread, hide: hiddenCategories) else { return false }
            return isWithinWindow(thread, newerThan: newerThan)
        }
    }

    static func partition(_ threads: [MailThread], mode: Mode,
                          vipThreadIds: Set<String> = [],
                          vipAlwaysPins: Bool = true,
                          hiddenCategories: Set<String> = [],
                          newerThan: Date? = nil,
                          maxCount: Int? = nil) -> (priority: [MailThread], rest: [MailThread]) {
        guard mode != .off else { return ([], threads) }
        let limit = cap(maxCount ?? 0)
        var priority: [MailThread] = []
        var rest: [MailThread] = []
        for thread in threads {
            if qualifies(thread, mode: mode, vipThreadIds: vipThreadIds,
                         vipAlwaysPins: vipAlwaysPins,
                         hiddenCategories: hiddenCategories,
                         newerThan: newerThan) {
                let isVIPExempt = vipAlwaysPins && vipThreadIds.contains(thread.id)
                let underCap = limit.map { priority.count < $0 } ?? true
                if underCap || isVIPExempt {
                    priority.append(thread)
                } else {
                    rest.append(thread)
                }
            } else {
                rest.append(thread)
            }
        }
        return (priority, rest)
    }

    /// `nil` window means no recency filter.
    private static func isWithinWindow(_ thread: MailThread, newerThan: Date?) -> Bool {
        guard let newerThan else { return true }
        return thread.lastDate >= newerThan
    }

    /// Membership matches `StarStickiness.isInHiddenCategory` / SQL CategoryHide.
    private static func isInHiddenCategory(_ thread: MailThread, hide: Set<String>) -> Bool {
        StarStickiness.isInHiddenCategory(
            hide: hide,
            inPromotions: thread.inPromotions,
            inSocial: thread.inSocial,
            labelIds: thread.labelIds)
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
