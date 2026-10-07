import XCTest
import GRDB

/// Undo of archive, trash, spam and snooze. The optimistic write persists
/// only columns that differ from its base (`OptimisticThreadWrite`), so the
/// undo must diff against the post-action copy. With the pre-action snapshot
/// as the base, no column differs and the database row keeps the action.
final class ThreadUndoTests: XCTestCase {
    private let account = "ron@x.com"
    private let pick = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeDB(threads: [(id: String, labels: String)]) throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: self.account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            for (id, labels) in threads {
                let threadId = "\(self.account):\(id)"
                try Message(id: "\(self.account):m-\(id)", accountId: self.account,
                            gmailId: "m-\(id)", threadId: threadId, fromHeader: "a@b.com",
                            toHeader: self.account, ccHeader: "", bccHeader: "",
                            subject: "Hello", date: Date(), snippet: "", bodyText: "",
                            bodyHTML: nil, messageIdHeader: "", referencesHeader: "",
                            labelIds: labels, isUnread: labels.contains("UNREAD"),
                            hasAttachment: false).insert(db)
                try SyncEngine.deriveThreads(db, for: [threadId], accountId: self.account)
            }
        }
        return q
    }

    private func thread(_ q: DatabaseQueue, _ id: String = "t1") throws -> MailThread {
        try XCTUnwrap(try q.read { try MailThread.fetchOne($0, key: "\(self.account):\(id)") })
    }

    /// The two writes the app makes: the action, then its undo.
    private func actThenUndo(_ q: DatabaseQueue, _ plan: ThreadUndo.Plan,
                             original: MailThread) throws {
        try q.write { db in
            try OptimisticThreadWrite.updateChangedColumns(db, from: original, to: plan.acted)
            try OptimisticThreadWrite.updateChangedColumns(db, from: plan.acted, to: plan.restored)
        }
    }

    // MARK: - The database row is really restored

    func testArchiveUndoRestoresTheInboxRow() throws {
        let q = try makeDB(threads: [("t1", "INBOX UNREAD")])
        let original = try thread(q)
        let plan = ThreadUndo.plan(.archive, original: original)
        try q.write { db in
            try OptimisticThreadWrite.updateChangedColumns(db, from: original, to: plan.acted)
        }
        XCTAssertFalse(try thread(q).inInbox)
        try q.write { db in
            try OptimisticThreadWrite.updateChangedColumns(db, from: plan.acted, to: plan.restored)
        }
        let row = try thread(q)
        XCTAssertTrue(row.inInbox)
        // Undo-archive stays read, as in Gmail.
        XCTAssertFalse(row.isUnread)
        XCTAssertEqual(plan.actRemote, .modify(remove: ["INBOX", "UNREAD"]))
        XCTAssertEqual(plan.undoRemote, .modify(add: ["INBOX"]))
    }

    /// The regression (93cf754): the pre-action snapshot as the diff base
    /// writes nothing, so the row stays archived.
    func testPreActionSnapshotAsBaseLeavesTheRowArchived() throws {
        let q = try makeDB(threads: [("t1", "INBOX")])
        let original = try thread(q)
        let plan = ThreadUndo.plan(.archive, original: original)
        try q.write { db in
            try OptimisticThreadWrite.updateChangedColumns(db, from: original, to: plan.acted)
            try OptimisticThreadWrite.updateChangedColumns(db, from: original, to: plan.restored)
        }
        XCTAssertFalse(try thread(q).inInbox)
    }

    func testTrashUndoRestoresTheRow() throws {
        let q = try makeDB(threads: [("t1", "INBOX")])
        let original = try thread(q)
        let plan = ThreadUndo.plan(.trash, original: original)
        XCTAssertTrue(plan.acted.inTrash)
        XCTAssertFalse(plan.acted.inInbox)
        try actThenUndo(q, plan, original: original)
        let row = try thread(q)
        XCTAssertFalse(row.inTrash)
        XCTAssertTrue(row.inInbox)
        XCTAssertEqual(row.labelIds, original.labelIds)
        XCTAssertEqual(plan.actRemote, .trash)
        XCTAssertEqual(plan.undoRemote, .modify(add: ["INBOX"], remove: ["TRASH"]))
    }

    func testSpamUndoRestoresTheRow() throws {
        let q = try makeDB(threads: [("t1", "INBOX")])
        let original = try thread(q)
        let plan = ThreadUndo.plan(.spam, original: original)
        XCTAssertTrue(plan.acted.inSpam)
        try actThenUndo(q, plan, original: original)
        let row = try thread(q)
        XCTAssertFalse(row.inSpam)
        XCTAssertTrue(row.inInbox)
        XCTAssertEqual(row.labelIds, original.labelIds)
        XCTAssertEqual(plan.undoRemote, .modify(add: ["INBOX"], remove: ["SPAM"]))
    }

    func testNotSpamUndoPutsTheRowBackInSpam() throws {
        let q = try makeDB(threads: [("t1", "SPAM")])
        let original = try thread(q)
        XCTAssertTrue(original.inSpam)
        let plan = ThreadUndo.plan(.notSpam, original: original)
        XCTAssertFalse(plan.acted.inSpam)
        XCTAssertTrue(plan.acted.inInbox)
        try actThenUndo(q, plan, original: original)
        let row = try thread(q)
        XCTAssertTrue(row.inSpam)
        XCTAssertFalse(row.inInbox)
        XCTAssertEqual(plan.undoRemote, .modify(add: ["SPAM"], remove: ["INBOX"]))
    }

    func testSnoozeUndoClearsSnoozeUntil() throws {
        let q = try makeDB(threads: [("t1", "INBOX")])
        let original = try thread(q)
        let plan = ThreadUndo.plan(.snooze(until: pick), original: original)
        try q.write { db in
            try OptimisticThreadWrite.updateChangedColumns(db, from: original, to: plan.acted)
        }
        XCTAssertEqual(try thread(q).snoozeUntil, pick)
        XCTAssertFalse(try thread(q).inInbox)
        try q.write { db in
            try OptimisticThreadWrite.updateChangedColumns(db, from: plan.acted, to: plan.restored)
        }
        let row = try thread(q)
        XCTAssertNil(row.snoozeUntil)
        XCTAssertTrue(row.inInbox)
        XCTAssertEqual(plan.undoRemote, .modify(add: ["INBOX"]))
    }

    // MARK: - A thread that was not in the inbox does not move there

    func testUndoOfAnArchivedThreadDoesNotAddInbox() throws {
        for action: ThreadUndo.Action in [.archive, .trash, .spam, .snooze(until: pick)] {
            let q = try makeDB(threads: [("t1", "Label_1")])
            let original = try thread(q)
            XCTAssertFalse(original.inInbox)
            let plan = ThreadUndo.plan(action, original: original)
            XCTAssertFalse(plan.undoRemote.addLabels.contains("INBOX"), "\(action)")
            try actThenUndo(q, plan, original: original)
            let row = try thread(q)
            XCTAssertFalse(row.inInbox, "\(action)")
            XCTAssertFalse(row.inTrash, "\(action)")
            XCTAssertFalse(row.inSpam, "\(action)")
            XCTAssertNil(row.snoozeUntil, "\(action)")
            XCTAssertFalse(row.labels.contains("INBOX"), "\(action)")
        }
    }

    func testUndoRemoteForAThreadOutsideTheInbox() {
        XCTAssertEqual(ThreadUndo.undoRemote(.trash, wasInInbox: false),
                       .modify(remove: ["TRASH"]))
        XCTAssertEqual(ThreadUndo.undoRemote(.spam, wasInInbox: false),
                       .modify(remove: ["SPAM"]))
        // Nothing to send: the action removed a label the thread did not have.
        XCTAssertTrue(ThreadUndo.undoRemote(.archive, wasInInbox: false).isEmpty)
        XCTAssertTrue(ThreadUndo.undoRemote(.snooze(until: pick), wasInInbox: false).isEmpty)
    }

    // MARK: - Bulk

    func testBulkUndoSplitsByTheOriginalInboxState() throws {
        let q = try makeDB(threads: [("t1", "INBOX"), ("t2", "Label_1"), ("t3", "INBOX")])
        let originals = try ["t1", "t2", "t3"].map { try thread(q, $0) }
        let acted = originals.map { ThreadUndo.plan(.trash, original: $0).acted }
        try q.write { db in
            for (original, acted) in zip(originals, acted) {
                try OptimisticThreadWrite.updateChangedColumns(db, from: original, to: acted)
            }
        }
        XCTAssertTrue(try ["t1", "t2", "t3"].allSatisfy { try thread(q, $0).inTrash })

        let groups = ThreadUndo.undoGroups(acted: acted, originals: originals)
        XCTAssertEqual(groups.map(\.wasInInbox), [true, false])
        XCTAssertEqual(groups[0].threads.map(\.gmailThreadId), ["t1", "t3"])
        XCTAssertEqual(groups[1].threads.map(\.gmailThreadId), ["t2"])

        try q.write { db in
            for group in groups {
                for base in group.threads {
                    var restored = base
                    ThreadUndo.restore(.trash, wasInInbox: group.wasInInbox, &restored)
                    try OptimisticThreadWrite.updateChangedColumns(db, from: base, to: restored)
                }
            }
        }
        XCTAssertTrue(try thread(q, "t1").inInbox)
        XCTAssertFalse(try thread(q, "t2").inInbox)
        XCTAssertTrue(try thread(q, "t3").inInbox)
        XCTAssertFalse(try ["t1", "t2", "t3"].contains { try thread(q, $0).inTrash })
    }

    func testBulkSnoozeUndoClearsEveryRow() throws {
        let q = try makeDB(threads: [("t1", "INBOX"), ("t2", "INBOX")])
        let originals = try ["t1", "t2"].map { try thread(q, $0) }
        let action = ThreadUndo.Action.snooze(until: pick)
        let acted = originals.map { ThreadUndo.plan(action, original: $0).acted }
        try q.write { db in
            for (original, acted) in zip(originals, acted) {
                try OptimisticThreadWrite.updateChangedColumns(db, from: original, to: acted)
            }
            for group in ThreadUndo.undoGroups(acted: acted, originals: originals) {
                for base in group.threads {
                    var restored = base
                    ThreadUndo.restore(action, wasInInbox: group.wasInInbox, &restored)
                    try OptimisticThreadWrite.updateChangedColumns(db, from: base, to: restored)
                }
            }
        }
        for id in ["t1", "t2"] {
            XCTAssertNil(try thread(q, id).snoozeUntil)
            XCTAssertTrue(try thread(q, id).inInbox)
        }
    }

    func testUndoGroupsDropEmptyGroups() {
        XCTAssertTrue(ThreadUndo.undoGroups(acted: [], originals: []).isEmpty)
    }
}
