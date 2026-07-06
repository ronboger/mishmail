import Foundation

/// Splits a thread list into the pinned Priority section and everything
/// else, preserving the incoming (date-sorted) order. What qualifies is a
/// user choice: starred only (a tight, hand-picked section), or starred plus
/// Gmail's IMPORTANT label (Gmail's own priority prediction — broader).
/// No local AI either way.
enum PrioritySplit {
    enum Mode: String, CaseIterable {
        case off
        case starred
        case starredImportant

        var title: String {
            switch self {
            case .off: return "Off — chronological"
            case .starred: return "Starred"
            case .starredImportant: return "Starred + Important"
            }
        }
    }

    static func qualifies(_ thread: MailThread, mode: Mode,
                          vipThreadIds: Set<String> = []) -> Bool {
        switch mode {
        case .off: return false
        case .starred:
            return thread.isStarred || vipThreadIds.contains(thread.id)
        case .starredImportant:
            return thread.isStarred || vipThreadIds.contains(thread.id)
                || thread.labels.contains("IMPORTANT")
        }
    }

    static func partition(_ threads: [MailThread], mode: Mode,
                          vipThreadIds: Set<String> = []) -> (priority: [MailThread], rest: [MailThread]) {
        guard mode != .off else { return ([], threads) }
        var priority: [MailThread] = []
        var rest: [MailThread] = []
        for thread in threads {
            if qualifies(thread, mode: mode, vipThreadIds: vipThreadIds) {
                priority.append(thread)
            } else {
                rest.append(thread)
            }
        }
        return (priority, rest)
    }
}
