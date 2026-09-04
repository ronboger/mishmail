import Foundation

/// Local follow-up reminders. Gmail has no snooze/reminder API, so these stay
/// on this Mac. Decision helpers live here so `MailStore` only owns the
/// observable write + notify.
enum LocalReminders {
    /// Compare-and-clear. The `AND reminderAt = ?` predicate is what makes
    /// the write safe across the await gap: a reminder the user sets after
    /// the snapshot is a different value and must survive.
    static let clearSQL = """
        UPDATE thread SET reminderAt = NULL, reminderSetAt = NULL
        WHERE id = ? AND reminderAt = ?
        """

    /// "Remind if no reply": only *inbound* activity cancels the nudge.
    /// Own follow-ups update lastDate but leave lastInboundDate alone
    /// (or nil for pure-outbound threads), so they don't look like a reply.
    static func inboundReplyCancels(reminderSetAt: Date?, lastInboundDate: Date?) -> Bool {
        reminderSetAt.flatMap { setAt in
            lastInboundDate.map { $0 > setAt }
        } ?? false
    }

    static func fireAt(after days: Int?, now: Date = Date(),
                       calendar: Calendar = .current) -> Date? {
        days.flatMap { calendar.date(byAdding: .day, value: $0, to: now) }
    }
}
