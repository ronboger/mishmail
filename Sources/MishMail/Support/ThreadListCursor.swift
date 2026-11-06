import Foundation

/// Cursor for thread-list pages ordered by sort-date DESC, id DESC.
/// `sortDate` is the value of the active sort key for that view
/// (`lastDate` for most mailboxes; `inboxSortDate` for inbox-style views).
struct ThreadListCursor: Equatable, Hashable {
    var sortDate: Date
    var id: String

    /// Backward-compat alias used by older tests/callers.
    var lastDate: Date {
        get { sortDate }
        set { sortDate = newValue }
    }

    static func from(_ thread: MailThread, inboundSort: Bool = false) -> ThreadListCursor {
        ThreadListCursor(
            sortDate: inboundSort ? thread.inboxSortDate : thread.lastDate,
            id: thread.id)
    }
}

/// Pure helpers for paginated list windows (Phase 4).
enum ThreadListPaging {
    /// Page size for first paint and load-older. Smaller than the old hard
    /// 300 so top-of-inbox reloads stay cheap; Load older expands the window.
    static let pageSize = 100

    /// Search is single-window (no Load older), so it keeps the historical
    /// 300-row depth rather than shrinking with `pageSize`.
    static let searchWindowLimit = 300

    /// True when a full page was returned — there may be older rows.
    /// Prefer `splitPage` (limit+1 probe) over this alone so exact multiples
    /// don't show a dead "Load older".
    static func hasMore(fetchedCount: Int, pageSize: Int = pageSize) -> Bool {
        fetchedCount >= pageSize
    }

    /// Split a `limit+1` fetch into the visible page and a definitive hasMore.
    static func splitPage(_ rows: [MailThread], pageSize: Int = pageSize)
        -> (page: [MailThread], hasMore: Bool) {
        let hasMore = rows.count > pageSize
        return (Array(rows.prefix(pageSize)), hasMore)
    }

    /// Fetch limit for a page probe (one extra row to detect hasMore).
    static func probeLimit(pageSize: Int = pageSize) -> Int { pageSize + 1 }

    /// Cursor after the last row of the current window (nil if empty).
    static func nextCursor(after threads: [MailThread], inboundSort: Bool = false)
        -> ThreadListCursor? {
        threads.last.map { ThreadListCursor.from($0, inboundSort: inboundSort) }
    }

    /// SQL expression for the active sort key (usable in ORDER BY / WHERE).
    static func sortDateSQL(inboundSort: Bool) -> String {
        inboundSort ? "COALESCE(lastInboundDate, lastDate)" : "lastDate"
    }

    /// SQL predicate for rows strictly older than `cursor` under
    /// `ORDER BY <sortDate> DESC, id DESC`.
    static func olderThanSQL(inboundSort: Bool = false) -> String {
        let key = sortDateSQL(inboundSort: inboundSort)
        return "(\(key) < ? OR (\(key) = ? AND id < ?))"
    }

    /// Date used for list *activity* (SQL order + date-section buckets).
    /// When `inboundSort` is true, own outbound does not advance the key.
    static func activityDate(of thread: MailThread, inboundSort: Bool) -> Date {
        inboundSort ? thread.inboxSortDate : thread.lastDate
    }
}

/// Pure "Today / Yesterday / …" bucketing for the thread list date group.
/// Kept free of SwiftUI so the "own reply must not re-hoist into Today"
/// contract is unit-testable.
enum ThreadDateSections {
    static let order = ["Today", "Yesterday", "Last 7 days", "Last 30 days", "Older"]

    /// Group threads by `dateKey`, preserving `order` section sequence.
    /// Within each bucket, original relative order of `threads` is kept
    /// (caller usually already sorted by the same activity date DESC).
    static func group(_ threads: [MailThread],
                      dateKey: (MailThread) -> Date,
                      now: Date = Date(),
                      calendar: Calendar = .current) -> [(String, [MailThread])] {
        guard !threads.isEmpty else { return [] }
        let today = calendar.dateInterval(of: .day, for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
            .flatMap { calendar.dateInterval(of: .day, for: $0) }
        let week = now.addingTimeInterval(-7 * 86_400)
        let month = now.addingTimeInterval(-30 * 86_400)
        var buckets: [String: [MailThread]] = [:]
        for thread in threads {
            let date = dateKey(thread)
            let key: String
            // Calendar days span local midnight to (but exclude) the next
            // midnight. The longer windows are rolling elapsed-time cutoffs.
            if let today, date >= today.start, date < today.end { key = "Today" }
            else if let yesterday, date >= yesterday.start, date < yesterday.end { key = "Yesterday" }
            else if date > week { key = "Last 7 days" }
            else if date > month { key = "Last 30 days" }
            else { key = "Older" }
            buckets[key, default: []].append(thread)
        }
        return order.compactMap { key in buckets[key].map { (key, $0) } }
    }
}
