import Foundation
import GRDB

/// Live `/` search panel thread preview (FTS → newest threads).
///
/// Extracted from `MailStore` so hostless tests exercise the real SQL
/// (MailStore is AppKit-bound and not in MishMailTests).
enum ThreadTypeahead {
    /// Minimum query length before FTS runs. One-character prefixes match
    /// too much of the mailbox under FTS5 prefix indexes.
    static let minimumQueryLength = 2

    /// Candidate threads kept from FTS before ranking by `thread.lastDate`.
    /// Sized so a 5-row panel has headroom without scanning every FTS hit.
    static func candidateCap(limit: Int) -> Int { max(limit * 16, 40) }

    /// Newest non-trash threads matching `query` via subject/from FTS.
    /// Empty when `query` is shorter than `minimumQueryLength` or has no hits.
    /// On an empty strict MATCH, retries once with a typo-tolerant pattern
    /// (`FuzzySearch`) so near-misses like "levis" still surface "Levi's".
    static func fetch(db: Database, query: String, limit: Int = 5) throws -> [MailThread] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= minimumQueryLength else { return [] }
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: q) else { return [] }
        let cap = candidateCap(limit: limit)
        let strict = try fetchMatching(db: db, pattern: pattern, cap: cap, limit: limit)
        if !strict.isEmpty { return strict }
        // Fallback-only: never re-rank or dilute a non-empty strict result.
        guard let fuzzy = try FuzzySearch.expandedPattern(db: db, text: q) else {
            return []
        }
        return try fetchMatching(db: db, pattern: fuzzy, cap: cap, limit: limit)
    }

    /// Shared MATCH → thread fetch (strict and fuzzy paths).
    /// Inner ORDER BY MAX(message.date) so the candidate cap prefers recent
    /// mail — without it SQLite keeps arbitrary rowid order and the outer
    /// lastDate sort only ranks within that biased set (typeahead miss).
    private static func fetchMatching(
        db: Database, pattern: FTS5Pattern, cap: Int, limit: Int
    ) throws -> [MailThread] {
        try MailThread.fetchAll(db, sql: """
            SELECT thread.*
            FROM (
                SELECT message.threadId AS tid, MAX(message.date) AS newest
                FROM message_fts
                JOIN message ON message.rowid = message_fts.rowid
                WHERE message_fts MATCH ?
                GROUP BY message.threadId
                ORDER BY newest DESC
                LIMIT ?
            ) AS hits
            JOIN thread ON thread.id = hits.tid
            WHERE thread.inTrash = 0
            ORDER BY thread.lastDate DESC
            LIMIT ?
            """, arguments: [pattern, cap, limit])
    }
}
