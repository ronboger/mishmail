import Foundation
import GRDB

/// Database side of an optimistic thread edit (archive, star, mark read,
/// labels, snooze). Pure over a `Database` so tests run it in memory.
///
/// An optimistic edit writes the thread row only. Message rows keep Gmail's
/// last known labels until history reports the edit; they are the source a
/// rejected edit reverts from.
enum OptimisticThreadWrite {
    /// Persist only columns changed by this user action. A whole-row save can
    /// overwrite a newer sync-derived subject, participant set, or reminder.
    static func updateChangedColumns(
        _ db: Database, from old: MailThread, to updated: MailThread
    ) throws {
        func update(_ column: String, _ value: (any DatabaseValueConvertible)?) throws {
            try db.execute(
                sql: "UPDATE thread SET \(column) = ? WHERE id = ?",
                arguments: [value, updated.id])
        }
        if old.subject != updated.subject { try update("subject", updated.subject) }
        if old.snippet != updated.snippet { try update("snippet", updated.snippet) }
        if old.fromDisplay != updated.fromDisplay { try update("fromDisplay", updated.fromDisplay) }
        if old.lastDate != updated.lastDate { try update("lastDate", updated.lastDate) }
        if old.isUnread != updated.isUnread { try update("isUnread", updated.isUnread) }
        if old.isStarred != updated.isStarred { try update("isStarred", updated.isStarred) }
        if old.inInbox != updated.inInbox { try update("inInbox", updated.inInbox) }
        if old.inTrash != updated.inTrash { try update("inTrash", updated.inTrash) }
        if old.labelIds != updated.labelIds {
            try update("labelIds", updated.labelIds)
            try ThreadLabels.rewrite(db, threadId: updated.id, labelIds: updated.labelIds)
        }
        if old.snoozeUntil != updated.snoozeUntil { try update("snoozeUntil", updated.snoozeUntil) }
        if old.participants != updated.participants { try update("participants", updated.participants) }
        if old.messageCount != updated.messageCount { try update("messageCount", updated.messageCount) }
        if old.hasAttachment != updated.hasAttachment { try update("hasAttachment", updated.hasAttachment) }
        if old.reminderAt != updated.reminderAt { try update("reminderAt", updated.reminderAt) }
        if old.reminderSetAt != updated.reminderSetAt { try update("reminderSetAt", updated.reminderSetAt) }
        if old.inSent != updated.inSent { try update("inSent", updated.inSent) }
        if old.inDrafts != updated.inDrafts { try update("inDrafts", updated.inDrafts) }
        if old.inPromotions != updated.inPromotions { try update("inPromotions", updated.inPromotions) }
        if old.inSocial != updated.inSocial { try update("inSocial", updated.inSocial) }
        if old.inSpam != updated.inSpam { try update("inSpam", updated.inSpam) }
        if old.fromEmail != updated.fromEmail { try update("fromEmail", updated.fromEmail) }
        if old.allFromEmails != updated.allFromEmails { try update("allFromEmails", updated.allFromEmails) }
        if old.lastInboundDate != updated.lastInboundDate {
            try update("lastInboundDate", updated.lastInboundDate)
        }
    }

    /// Undo an optimistic thread edit that Gmail rejected (or an offline
    /// replay that was dropped). Optimistic edits change only the thread row;
    /// message rows keep Gmail's last known labels. Re-deriving the thread
    /// from its messages therefore restores exactly what Gmail holds.
    static func rederiveOrDelete(
        _ db: Database, threadId: String, accountId: String
    ) throws {
        let hasMessages = try Message
            .filter(Column("threadId") == threadId)
            .fetchCount(db) > 0
        if hasMessages {
            try SyncEngine.deriveThreads(db, for: [threadId], accountId: accountId)
        } else {
            _ = try MailThread.deleteOne(db, key: threadId)
            try ThreadLabels.rewrite(db, threadId: threadId, labelIds: "")
        }
    }

}
