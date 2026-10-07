import Foundation
import GRDB

/// Thread query for a committed search (the search branch of
/// `MailStore.reloadThreads`).
///
/// Extracted from `MailStore` so hostless unit tests run the production SQL
/// against an in-memory database — same pattern as `SearchFTS` and
/// `ThreadListQuery`. `MailStore` only snapshots its MainActor state into a
/// `Context` and calls `fetch`.
enum SearchThreadQuery {
    /// MainActor state the query needs, captured before the pool read.
    struct Context {
        /// Every known label (all accounts) for `label:` name resolution.
        var labels: [LabelRow] = []
        /// Threads just marked read/unread: they stay listed under
        /// `is:unread` / `is:read` (same as filter chips).
        var keepIds: [String] = []
        /// Just-unstarred threads: they stay under `is:starred` until the
        /// search is cleared (read-state keepIds parity).
        var starKeepIds: [String] = []
        /// Sidebar account focus; nil searches every account.
        var accountId: String?
    }

    /// Threads matching `search`, without ORDER BY / LIMIT.
    static func request(search: String, db: Database,
                        context: Context) throws -> QueryInterfaceRequest<MailThread> {
        let parsed = SearchQuery.parse(search)
        var q = MailThread.all()
        if !parsed.text.isEmpty {
            q = try SearchFTS.filter(q, db: db, text: parsed.text)
        }
        if let from = parsed.from {
            // fromDisplay/participants hold display names, so an email
            // query ("from:x@y.com") must also check the raw header.
            // Prefer denorm fromEmail when present; still check headers
            // for threads not yet backfilled.
            let pattern = "%\(from)%"
            q = q.filter(sql: """
                (fromDisplay LIKE ? OR participants LIKE ?
                 OR fromEmail LIKE ?
                 OR EXISTS (SELECT 1 FROM message
                            WHERE message.threadId = thread.id
                              AND message.fromHeader LIKE ?))
                """, arguments: [pattern, pattern, pattern, pattern])
        }
        if let to = parsed.to {
            // Recipient headers live on messages, so match via EXISTS.
            q = q.filter(sql: """
                EXISTS (SELECT 1 FROM message
                        WHERE message.threadId = thread.id
                          AND (message.toHeader LIKE ? OR message.ccHeader LIKE ?
                               OR message.bccHeader LIKE ?))
                """, arguments: ["%\(to)%", "%\(to)%", "%\(to)%"])
        }
        if let subject = parsed.subject {
            q = q.filter(sql: "subject LIKE ?", arguments: ["%\(subject)%"])
        }
        if let unread = parsed.unread {
            q = q.filter(Column("isUnread") == unread
                         || context.keepIds.contains(Column("id")))
        }
        if parsed.starred {
            q = q.filter(Column("isStarred") == true
                         || context.starKeepIds.contains(Column("id")))
        }
        if let after = parsed.after {
            q = q.filter(Column("lastDate") >= after)
        }
        if let before = parsed.before {
            q = q.filter(Column("lastDate") < before)
        }
        for name in parsed.labels {
            // A label name resolves to Gmail label ids (it can exist on
            // several accounts); unknown names fall back to the raw
            // token uppercased, which covers system labels (STARRED…).
            var ids = context.labels
                .filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                .map(\.gmailLabelId)
            if ids.isEmpty { ids = [name.uppercased()] }
            q = filter(q, matchingLabelIds: ids, starKeepIds: context.starKeepIds)
        }
        if parsed.hasAttachment { q = q.filter(Column("hasAttachment") == true) }
        // Gmail search excludes trash/spam unless in:trash / in:spam /
        // in:anywhere. Without this, optimistic trash removes the row
        // and the async reload immediately brings it back.
        switch parsed.location {
        case .standard:
            q = q.filter(Column("inTrash") == false && Column("inSpam") == false)
        case .trash:
            q = q.filter(Column("inTrash") == true)
        case .spam:
            q = q.filter(Column("inSpam") == true)
        case .anywhere:
            break
        }
        if let accountId = context.accountId {
            q = q.filter(Column("accountId") == accountId)
        }
        return q
    }

    /// One window of results. Search always ranks by newest message
    /// (`lastDate`), with `id` as the tie-break.
    static func fetch(search: String, db: Database, context: Context,
                      limit: Int) throws -> [MailThread] {
        try request(search: search, db: db, context: context)
            .order(Column("lastDate").desc, Column("id").desc)
            .limit(limit).fetchAll(db)
    }

    /// Match threads that have any of `labelIds`. Same rules as
    /// `MailStore.filterThreads(_:matchingLabelIds:starKeepIds:)`, which is
    /// App-bound and not in the hostless target: user labels (`Label_*`) use
    /// the `thread_label` junction; system / category labels use the denorm
    /// flags, else `labelIds LIKE`.
    static func filter(
        _ q: QueryInterfaceRequest<MailThread>,
        matchingLabelIds ids: [String],
        starKeepIds: [String] = []
    ) -> QueryInterfaceRequest<MailThread> {
        guard !ids.isEmpty else { return q }
        let user = ids.filter { $0.hasPrefix("Label_") }
        let system = ids.filter { !$0.hasPrefix("Label_") }
        var parts: [String] = []
        var args: [any DatabaseValueConvertible] = []
        if !user.isEmpty {
            let ors = user.map { _ in
                "EXISTS (SELECT 1 FROM thread_label WHERE threadId = thread.id AND labelId = ?)"
            }.joined(separator: " OR ")
            parts.append("(\(ors))")
            args.append(contentsOf: user)
        }
        for s in system {
            switch s {
            case "STARRED":
                if starKeepIds.isEmpty {
                    parts.append("isStarred = 1")
                } else {
                    let placeholders = starKeepIds.map { _ in "?" }.joined(separator: ",")
                    parts.append("(isStarred = 1 OR id IN (\(placeholders)))")
                    args.append(contentsOf: starKeepIds)
                }
            case "INBOX": parts.append("inInbox = 1")
            case "TRASH": parts.append("inTrash = 1")
            case "SENT": parts.append("inSent = 1")
            case "DRAFT": parts.append("inDrafts = 1")
            case "SPAM": parts.append("inSpam = 1")
            case "CATEGORY_PROMOTIONS": parts.append("inPromotions = 1")
            case "CATEGORY_SOCIAL": parts.append("inSocial = 1")
            default:
                parts.append("labelIds LIKE ?")
                args.append("%\(s)%")
            }
        }
        guard !parts.isEmpty else { return q }
        return q.filter(sql: "(\(parts.joined(separator: " OR ")))",
                        arguments: StatementArguments(args))
    }
}
