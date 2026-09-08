import Foundation
import GRDB

/// Which linked mailbox a brand-new compose should send from, judged by who
/// it is addressed to.
///
/// A `mailto:` handoff (Notion Calendar's `e e`, a browser link) carries the
/// recipients but not the account the user was acting as. Defaulting to the
/// *active* sidebar account picks the wrong From whenever the invite arrived
/// in another mailbox. The strongest local evidence is the most recent
/// non-draft message that names one of those recipients in From/To/Cc: the
/// mailbox that message lives in is the one the user corresponds with them
/// through.
///
/// The lookup rides on `message_fts` (subject + from + to + cc since v33),
/// so it needs no new index and no full-table scan: FTS narrows to the rows
/// that mention the address tokens, SQLite orders that small set by date,
/// and Swift confirms the exact address on the top few rows. Drafts are
/// excluded so a wrong first guess cached in Gmail Drafts cannot feed itself
/// back in as evidence.
enum RecipientMailbox {

    /// Candidates newest-first; Swift verifies the address on each so a
    /// display-name collision on the tokens cannot pick a mailbox.
    static let candidateLimit = 200

    /// Tokens FTS5's unicode61 tokenizer would produce for `address`, joined
    /// as a phrase. `"dana@brightloop.io"` → `"dana brightloop io"`. nil when
    /// the address has no alphanumeric content.
    static func phrase(for address: String) -> String? {
        let tokens = address.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return "\"" + tokens.joined(separator: " ") + "\""
    }

    /// FTS5 MATCH expression restricted to the header columns. Tokens are
    /// alphanumeric only (see `phrase`), so the string needs no escaping.
    static func matchExpression(for addresses: [String]) -> String? {
        let phrases = addresses.compactMap(phrase(for:))
        guard !phrases.isEmpty else { return nil }
        return "{fromHeader toHeader ccHeader} : (" + phrases.joined(separator: " OR ") + ")"
    }

    /// Mailbox (`Account.id`) of the newest non-draft message that names any
    /// of `addresses` in From, To, or Cc. nil when nothing local mentions them.
    static func mostRecentMailbox(db: Database, addresses: [String]) throws -> String? {
        let wanted = Set(addresses.map { $0.lowercased() }
            .filter { !$0.isEmpty })
        guard !wanted.isEmpty,
              let match = matchExpression(for: Array(wanted)) else { return nil }
        let rows = try Row.fetchAll(db, sql: """
            SELECT message.accountId AS accountId,
                   message.fromHeader AS fromHeader,
                   message.toHeader AS toHeader,
                   message.ccHeader AS ccHeader
            FROM message_fts
            JOIN message ON message.rowid = message_fts.rowid
            WHERE message_fts MATCH ?
              AND message.labelIds NOT LIKE '%DRAFT%'
            ORDER BY message.date DESC
            LIMIT ?
            """, arguments: [match, candidateLimit])
        for row in rows {
            let headers: [String] = [row["fromHeader"], row["toHeader"], row["ccHeader"]]
            let mentioned = headers.flatMap(MessageParser.splitAddresses)
                .map { MessageParser.emailAddress($0).lowercased() }
            if mentioned.contains(where: wanted.contains) {
                return row["accountId"]
            }
        }
        return nil
    }
}
