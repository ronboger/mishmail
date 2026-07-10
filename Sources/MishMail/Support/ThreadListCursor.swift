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
    /// First page size (matches historical hard limit).
    static let pageSize = 300

    /// True when a full page was returned — there may be older rows.
    static func hasMore(fetchedCount: Int, pageSize: Int = pageSize) -> Bool {
        fetchedCount >= pageSize
    }

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
