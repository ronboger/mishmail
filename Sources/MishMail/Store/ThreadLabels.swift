import Foundation
import GRDB

/// Rewrites `thread_label` rows for a thread from its space-separated
/// `labelIds`. Only Gmail user labels (`Label_*`) are stored; system labels
/// stay on denorm flags.
enum ThreadLabels {
    /// Replace junction rows for `threadId` with the user labels in `labelIds`.
    static func rewrite(_ db: Database, threadId: String, labelIds: String) throws {
        try db.execute(sql: "DELETE FROM thread_label WHERE threadId = ?",
                       arguments: [threadId])
        let user = labelIds.split(separator: " ").map(String.init)
            .filter { $0.hasPrefix("Label_") }
        for lab in user {
            try ThreadLabel(threadId: threadId, labelId: lab).insert(db)
        }
    }

    /// Space-separated unique lowercased From emails across `messages`.
    static func allFromEmails(from messages: [Message]) -> String {
        var seen = Set<String>()
        var ordered: [String] = []
        for m in messages {
            let e = MessageParser.emailAddress(m.fromHeader).lowercased()
            guard e.contains("@"), seen.insert(e).inserted else { continue }
            ordered.append(e)
        }
        return ordered.joined(separator: " ")
    }

    /// True when any token in `allFromEmails` (or `fromEmail`) is in `blocked`.
    static func matchesBlocklist(fromEmail: String, allFromEmails: String,
                                 blocked: Set<String>) -> Bool {
        if !fromEmail.isEmpty, blocked.contains(fromEmail) { return true }
        for part in allFromEmails.split(separator: " ") {
            if blocked.contains(String(part)) { return true }
        }
        return false
    }
}
