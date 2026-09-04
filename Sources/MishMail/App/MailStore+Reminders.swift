import Foundation
import SwiftUI
import AppKit
import GRDB

extension MailStore {
    // MARK: - Reminders

    func setReminder(_ thread: MailThread, after days: Int?) {
        var copy = thread
        let when = LocalReminders.fireAt(after: days)
        copy.reminderAt = when
        // Snapshot the thread's current activity so the reminder can cancel
        // itself if a newer message arrives ("remind if no reply").
        copy.reminderSetAt = when == nil ? nil : Date()
        let updated = copy
        try? db.write { db in try updated.save(db) }
        reloadThreads()
    }

    /// Async: this fires on every poll tick, and the overwhelming majority of
    /// ticks find nothing due. Paying for a main-thread reader to learn that
    /// was the same once-a-minute tax as the rest of the sync tail.
    func fireDueReminders() async {
        let pool = db
        let due = (try? await pool.read { db in
            try MailThread.filter(Column("reminderAt") != nil && Column("reminderAt") <= Date()).fetchAll(db)
        }) ?? []
        var changed = false
        for thread in due {
            changed = true
            // "Remind if no reply": only *inbound* activity cancels the nudge.
            // Own follow-ups update lastDate but leave lastInboundDate alone
            // (or nil for pure-outbound threads), so they don't look like a reply.
            // Snapshot is fine for the notify decision; only the write must be
            // narrow — whole-row save from the pre-await snapshot would clobber
            // concurrent user mutations (star, archive, …) that landed in the gap.
            let replied = LocalReminders.inboundReplyCancels(
                reminderSetAt: thread.reminderSetAt,
                lastInboundDate: thread.lastInboundDate)
            if !replied {
                Notifier.notify(title: "Follow up: \(thread.fromDisplay)",
                                body: thread.subject.isEmpty ? thread.snippet : thread.subject,
                                id: "reminder.\(thread.id)")
            }
            // Compare-and-clear: the narrow UPDATE is only *safe* because of
            // `AND reminderAt = ?`. Without the predicate, a reminder the user
            // sets on this thread during the await gap (after the snapshot,
            // before the write) would be silently wiped. Matching the
            // snapshot's value means we only clear the reminder we actually
            // read — narrow alone is not enough.
            try? await db.write { db in
                try db.execute(
                    sql: LocalReminders.clearSQL,
                    arguments: [thread.id, thread.reminderAt])
            }
        }
        if changed { reloadThreads() }
    }
}
