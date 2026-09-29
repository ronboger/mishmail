import Foundation
import GRDB

/// Resolves a `mishmail://thread/<token>` deep link to a local thread.
///
/// Extracted from `MailStore` so hostless unit tests share the exact lookup
/// order (no AppKit), and so the caller can run it on a pool reader instead
/// of the main actor.
///
/// Row ids are `"<account>:<gmailId>"` for both `thread` and `message`, so a
/// link whose account we know resolves by primary key — no scan. The
/// `gmailThreadId` / `message.gmailId` columns carry no index and the
/// `lower(accountId)` match cannot use one either, so the scans are a last
/// resort for tokens the key probes miss (an account id whose casing differs
/// from every linked mailbox, or a link without `?account=`).
enum DeepLinkThreadResolver {

    /// Primary-key probes for `token`, most specific first.
    ///
    /// With an account: the link's spelling, then every linked account that
    /// matches it case-insensitively (a link typed as `Me@X.com` still hits
    /// `me@x.com:<token>`). Without one: every linked account — Gmail ids are
    /// per mailbox, so the token can only belong to one of them.
    static func primaryKeys(token: String, accountEmail: String?,
                            knownAccountIds: [String]) -> [String] {
        var accounts: [String] = []
        if let accountEmail {
            accounts.append(accountEmail)
            accounts += knownAccountIds.filter {
                $0.caseInsensitiveCompare(accountEmail) == .orderedSame
            }
        } else {
            accounts = knownAccountIds
        }
        var seen = Set<String>()
        return accounts
            .map { "\($0):\(token)" }
            .filter { seen.insert($0).inserted }
    }

    /// Thread for `token` (a Gmail thread id or message id), or nil.
    ///
    /// Order matches the pre-extraction lookup: thread keys, then message
    /// keys, then the unindexed thread-token and message-token scans. When
    /// several keys hit (no account on the link), the newest wins — the same
    /// `ORDER BY … DESC LIMIT 1` tie-break the scans use.
    static func resolve(db: Database, token: String, accountEmail: String?,
                        knownAccountIds: [String]) throws -> MailThread? {
        let keys = primaryKeys(token: token, accountEmail: accountEmail,
                               knownAccountIds: knownAccountIds)

        let threadHits = try keys.compactMap { try MailThread.fetchOne(db, key: $0) }
        if let newest = threadHits.max(by: { $0.lastDate < $1.lastDate }) {
            return newest
        }

        // Message token: newest matching message's thread. Only the id and
        // date are read — a full `Message` row decode is wasted work here.
        var bestMessage: (threadId: String, date: Date)?
        for key in keys {
            guard let row = try Row.fetchOne(
                db, sql: "SELECT threadId, date FROM message WHERE id = ?",
                arguments: [key]) else { continue }
            let hit = (threadId: row["threadId"] as String, date: row["date"] as Date)
            if bestMessage.map({ hit.date > $0.date }) ?? true { bestMessage = hit }
        }
        if let bestMessage,
           let thread = try MailThread.fetchOne(db, key: bestMessage.threadId) {
            return thread
        }

        // Fallback scans (no index on the token columns).
        if let accountEmail {
            if let byThreadToken = try MailThread.fetchOne(
                db,
                sql: """
                    SELECT * FROM thread
                    WHERE gmailThreadId = ? AND lower(accountId) = lower(?)
                    ORDER BY lastDate DESC LIMIT 1
                    """,
                arguments: [token, accountEmail]) {
                return byThreadToken
            }
            return try MailThread.fetchOne(
                db,
                sql: """
                    SELECT thread.* FROM message
                    JOIN thread ON thread.id = message.threadId
                    WHERE message.gmailId = ? AND lower(message.accountId) = lower(?)
                    ORDER BY message.date DESC LIMIT 1
                    """,
                arguments: [token, accountEmail])
        }

        if let byThreadToken = try MailThread.fetchOne(
            db,
            sql: "SELECT * FROM thread WHERE gmailThreadId = ? ORDER BY lastDate DESC LIMIT 1",
            arguments: [token]) {
            return byThreadToken
        }
        return try MailThread.fetchOne(
            db,
            sql: """
                SELECT thread.* FROM message
                JOIN thread ON thread.id = message.threadId
                WHERE message.gmailId = ?
                ORDER BY message.date DESC LIMIT 1
                """,
            arguments: [token])
    }
}
