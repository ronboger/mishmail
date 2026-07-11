import Foundation

/// Cursor for thread-list pages ordered by `lastDate DESC, id DESC`.
struct ThreadListCursor: Equatable, Hashable {
    var lastDate: Date
    var id: String

    static func from(_ thread: MailThread) -> ThreadListCursor {
        ThreadListCursor(lastDate: thread.lastDate, id: thread.id)
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
    static func nextCursor(after threads: [MailThread]) -> ThreadListCursor? {
        threads.last.map(ThreadListCursor.from)
    }

    /// SQL predicate for rows strictly older than `cursor` under
    /// `ORDER BY lastDate DESC, id DESC`.
    static func olderThanSQL() -> String {
        "(lastDate < ? OR (lastDate = ? AND id < ?))"
    }
}
