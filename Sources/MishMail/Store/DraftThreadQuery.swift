import GRDB

/// Draft-only navigation needs message labels, never message bodies.
enum DraftThreadQuery {
    static func isDraftOnly(db: Database, threadId: String,
                            suppressing ids: Set<String>) throws -> Bool {
        let rows = try Row.fetchCursor(
            db, sql: "SELECT id, labelIds FROM message WHERE threadId = ?",
            arguments: [threadId])
        var hasVisibleMessage = false
        while let row = try rows.next() {
            let id: String = row["id"]
            guard !ids.contains(id) else { continue }
            let labels: String = row["labelIds"]
            guard ForwardComposer.isLiveDraft(labels) else { return false }
            hasVisibleMessage = true
        }
        return hasVisibleMessage
    }
}
