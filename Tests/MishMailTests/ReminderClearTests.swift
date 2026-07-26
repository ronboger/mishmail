import XCTest
import GRDB

/// The compare-and-clear write in `MailStore.fireDueReminders`.
///
/// That function reads due threads on a pool reader, suspends, then clears the
/// reminder columns. The write is deliberately narrow *and* conditional:
///
///     UPDATE thread SET reminderAt = NULL, reminderSetAt = NULL
///     WHERE id = ? AND reminderAt = ?
///
/// The predicate is what makes it safe — it only clears the reminder that was
/// actually read, so a reminder the user sets during the await gap survives.
///
/// It also has a silent failure mode worth pinning: `reminderAt` is a `Date`,
/// which GRDB stores as millisecond-precision text. If binding a round-tripped
/// Date produced even a slightly different string than the stored one, the
/// predicate would never match — reminders would never clear and would
/// re-notify on every poll tick, with nothing in the logs to say why. These
/// tests assert the match works and that the guard actually guards.
final class ReminderClearTests: XCTestCase {

    private let account = "ron@x.com"

    private func migrate() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        // `thread.accountId` is a foreign key — the owning account has to
        // exist before any thread row will insert.
        try q.write { db in
            try Account(id: self.account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
        }
        return q
    }

    private func thread(reminderAt: Date?, setAt: Date? = nil) -> MailThread {
        MailThread(
            id: "\(account):t1", accountId: account, gmailThreadId: "t1",
            subject: "Follow up", snippet: "snip", fromDisplay: "Jane",
            lastDate: Date(timeIntervalSince1970: 1_751_500_000),
            isUnread: false, isStarred: false, inInbox: true, inTrash: false,
            labelIds: "INBOX", snoozeUntil: nil, participants: "Jane",
            messageCount: 1, hasAttachment: false,
            reminderAt: reminderAt, reminderSetAt: setAt)
    }

    /// The exact statement `fireDueReminders` issues.
    private func clear(_ db: Database, id: String, matching reminderAt: Date?) throws {
        try db.execute(
            sql: """
                UPDATE thread SET reminderAt = NULL, reminderSetAt = NULL
                WHERE id = ? AND reminderAt = ?
                """,
            arguments: [id, reminderAt])
    }

    /// A Date read back out of the database and bound again must match the
    /// stored value. This is the encoding round-trip the predicate depends on.
    func testClearsWhenReminderStillMatchesTheSnapshot() throws {
        let q = try migrate()
        let due = Date(timeIntervalSince1970: 1_751_499_999.640)
        try q.write { db in try self.thread(reminderAt: due, setAt: due).save(db) }

        // Read the snapshot the way fireDueReminders does, then clear with it.
        let snapshot = try q.read { db in
            try MailThread.fetchOne(db, key: "\(self.account):t1")
        }
        XCTAssertNotNil(snapshot?.reminderAt)
        try q.write { db in
            try self.clear(db, id: snapshot!.id, matching: snapshot!.reminderAt)
        }

        let after = try q.read { db in try MailThread.fetchOne(db, key: "\(self.account):t1") }
        XCTAssertNil(after?.reminderAt, "the reminder that was read should be cleared")
        XCTAssertNil(after?.reminderSetAt)
    }

    /// The whole point of the predicate: a reminder written during the await
    /// gap is a different value, so the stale clear must not touch it.
    func testDoesNotClearAReminderSetDuringTheAwaitGap() throws {
        let q = try migrate()
        let due = Date(timeIntervalSince1970: 1_751_499_999.640)
        try q.write { db in try self.thread(reminderAt: due, setAt: due).save(db) }

        let snapshot = try q.read { db in
            try MailThread.fetchOne(db, key: "\(self.account):t1")
        }

        // User sets a new reminder after the snapshot was taken.
        let rescheduled = Date(timeIntervalSince1970: 1_751_600_000.100)
        try q.write { db in
            var row = try MailThread.fetchOne(db, key: "\(self.account):t1")!
            row.reminderAt = rescheduled
            row.reminderSetAt = rescheduled
            try row.update(db)
        }
        // Compare against the *stored* form, not the in-memory Date. Storage is
        // millisecond text, and the Double nearest a given fractional second
        // does not survive that round trip bit-for-bit — the two differ around
        // 1e-7 while `Date.description` truncates to seconds and prints them
        // identically. This is also exactly why `fireDueReminders` must clear
        // using the value it read from the database rather than a fresh Date.
        let stored = try q.read { db in
            try MailThread.fetchOne(db, key: "\(self.account):t1")?.reminderAt
        }
        XCTAssertNotNil(stored)

        // The in-flight clear carries the *old* value and must be a no-op.
        try q.write { db in
            try self.clear(db, id: snapshot!.id, matching: snapshot!.reminderAt)
        }

        let after = try q.read { db in try MailThread.fetchOne(db, key: "\(self.account):t1") }
        XCTAssertEqual(after?.reminderAt, stored,
                       "a reminder set during the await gap must survive the stale clear")
        XCTAssertEqual(after?.reminderSetAt, stored)
    }

    /// Sub-millisecond input is truncated on write, so a snapshot taken from
    /// the database always carries the truncated form and still matches.
    /// (Binding an *untruncated* in-memory Date would not — which is why
    /// fireDueReminders must clear using the value it read, not a fresh one.)
    func testSubMillisecondPrecisionSurvivesTheRoundTrip() throws {
        let q = try migrate()
        let precise = Date(timeIntervalSince1970: 1_751_499_999.6404999)
        try q.write { db in try self.thread(reminderAt: precise, setAt: precise).save(db) }

        let snapshot = try q.read { db in
            try MailThread.fetchOne(db, key: "\(self.account):t1")
        }
        try q.write { db in
            try self.clear(db, id: snapshot!.id, matching: snapshot!.reminderAt)
        }

        let after = try q.read { db in try MailThread.fetchOne(db, key: "\(self.account):t1") }
        XCTAssertNil(after?.reminderAt,
                     "a snapshot read from the database must match its own stored value")
    }
}
