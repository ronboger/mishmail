import Foundation
import GRDB

/// Full-text part of the committed-search thread query.
///
/// Extracted from `MailStore.reloadThreads` so hostless unit tests run the
/// production SQL (same pattern as `CategoryHide`).
///
/// The match used to be pulled into Swift as a thread-id array and bound
/// back as `id IN (?, ?, …)`. A short prefix ("a", "re") matches most of a
/// large mailbox, and past SQLITE_MAX_VARIABLE_NUMBER that statement fails —
/// and the reload's `try?` turned the failure into an empty result list.
/// It also round-tripped every id through Swift for nothing. Now the match
/// stays in SQL as a subquery, so there is no bind limit and SQLite can stop
/// once the outer LIMIT is filled.
enum SearchFTS {
    /// Thread ids whose messages match the FTS pattern bound to `?`.
    static let matchingThreadIdsSQL = """
        SELECT message.threadId FROM message
        JOIN message_fts ON message_fts.rowid = message.rowid
        WHERE message_fts MATCH ?
        """

    /// Restrict `query` to threads with a message matching `text`.
    ///
    /// Strict prefix FTS first; fuzzy only when that matches nothing, so typo
    /// expansion never dilutes exact/prefix hits. When neither applies, the
    /// strict pattern stays bound and the filter matches nothing — the same
    /// empty result the old empty id list produced.
    static func filter(_ query: QueryInterfaceRequest<MailThread>,
                       db: Database,
                       text: String) throws -> QueryInterfaceRequest<MailThread> {
        let strict = FTS5Pattern(matchingAllPrefixesIn: text)
        var pattern: FTS5Pattern? = strict
        // EXISTS stops at the first hit — the cheap way to ask "empty?".
        let strictHits = try Bool.fetchOne(
            db, sql: "SELECT EXISTS (\(matchingThreadIdsSQL))",
            arguments: [strict]) ?? false
        if !strictHits,
           let fuzzy = try FuzzySearch.expandedPattern(db: db, text: text) {
            pattern = fuzzy
        }
        return query.filter(sql: "thread.id IN (\(matchingThreadIdsSQL))",
                            arguments: [pattern])
    }
}
