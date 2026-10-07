import XCTest
import GRDB

/// SystemLabelReconcile — the history-expired reconcile corrects system
/// labels on cached rows from the id listings, and only on positive evidence.
final class SystemLabelReconcileTests: XCTestCase {
    typealias Listing = SystemLabelReconcile.Listing
    typealias Membership = SystemLabelReconcile.Membership

    private let account = "a@x.com"
    private let other = "b@x.com"

    /// Every listing complete and empty unless named.
    private func membership(window: Set<String> = ["m"],
                            inbox: Listing = Listing(ids: [], complete: true),
                            unread: Listing = Listing(ids: [], complete: true),
                            starred: Listing = Listing(ids: [], complete: true),
                            trash: Listing = Listing(ids: [], complete: true),
                            spam: Listing = Listing(ids: [], complete: true)) -> Membership {
        Membership(window: window, inbox: inbox, unread: unread,
                   starred: starred, trash: trash, spam: spam)
    }

    private func reconcile(_ current: String, _ m: Membership,
                           insideWindow: Bool = true) -> String {
        SystemLabelReconcile.reconciledLabelIds(
            current: current, gmailId: "m", insideWindow: insideWindow, membership: m)
    }

    private func with(_ label: String, _ listing: Listing) -> Membership {
        switch label {
        case "INBOX": return membership(inbox: listing)
        case "UNREAD": return membership(unread: listing)
        default: return membership(starred: listing)
        }
    }

    // MARK: - INBOX / UNREAD / STARRED: label × complete × present

    func testLabelPresentInCompleteListingIsAdded() {
        for label in ["INBOX", "UNREAD", "STARRED"] {
            let m = with(label, Listing(ids: ["m"], complete: true))
            XCTAssertEqual(reconcile("CATEGORY_X", m), "CATEGORY_X \(label)", label)
            XCTAssertEqual(reconcile("CATEGORY_X \(label)", m), "CATEGORY_X \(label)", label)
        }
    }

    func testLabelPresentInIncompleteListingIsAdded() {
        for label in ["INBOX", "UNREAD", "STARRED"] {
            let m = with(label, Listing(ids: ["m"], complete: false))
            XCTAssertEqual(reconcile("CATEGORY_X", m), "CATEGORY_X \(label)", label)
        }
    }

    func testLabelAbsentFromCompleteListingIsRemoved() {
        for label in ["INBOX", "UNREAD", "STARRED"] {
            let m = with(label, Listing(ids: ["other"], complete: true))
            XCTAssertEqual(reconcile("Label_1 \(label)", m), "Label_1", label)
            XCTAssertEqual(reconcile("Label_1", m), "Label_1", label)
        }
    }

    func testLabelAbsentFromIncompleteListingIsKept() {
        for label in ["INBOX", "UNREAD", "STARRED"] {
            // The other two listings are incomplete too: nothing may go.
            let cut = Listing(ids: ["other"], complete: false)
            let m = membership(inbox: cut, unread: cut, starred: cut)
            XCTAssertEqual(reconcile("Label_1 \(label)", m), "Label_1 \(label)", label)
            XCTAssertEqual(reconcile("Label_1", m), "Label_1", label)
        }
    }

    /// One truncated listing must not block the others.
    func testEachListingDecidesItsOwnLabel() {
        let m = membership(inbox: Listing(ids: [], complete: false),
                           unread: Listing(ids: [], complete: true),
                           starred: Listing(ids: ["m"], complete: false))
        XCTAssertEqual(reconcile("INBOX UNREAD", m), "INBOX STARRED")
    }

    func testArchivedAndReadOnPhone() {
        // The audit scenario: cached INBOX UNREAD, Gmail holds neither.
        XCTAssertEqual(reconcile("CATEGORY_UPDATES INBOX UNREAD", membership()),
                       "CATEGORY_UPDATES")
    }

    // MARK: - Window coverage

    func testRowNotInWindowListingIsNeverChanged() {
        let m = membership(window: ["other"],
                           inbox: Listing(ids: ["m"], complete: true),
                           starred: Listing(ids: ["m"], complete: true))
        for current in ["INBOX UNREAD STARRED", "Label_1", "TRASH", "SPAM UNREAD", ""] {
            XCTAssertEqual(reconcile(current, m), current, current)
        }
    }

    /// At the window's old edge the windowed listings may have aged the
    /// message out: INBOX and UNREAD can be added, never removed. STARRED is
    /// listed for all time, so it still follows its listing.
    func testRowAtWindowEdgeKeepsInboxAndUnread() {
        XCTAssertEqual(reconcile("INBOX STARRED UNREAD", membership(), insideWindow: false),
                       "INBOX UNREAD")
        let m = membership(inbox: Listing(ids: ["m"], complete: true),
                           unread: Listing(ids: ["m"], complete: true))
        XCTAssertEqual(reconcile("", m, insideWindow: false), "INBOX UNREAD")
    }

    // MARK: - TRASH / SPAM

    func testRowInWindowListingLosesTrashAndSpam() {
        // Untrashed / marked not-spam on the phone: the window listing
        // names it, and that listing excludes Trash and Spam.
        let m = membership(inbox: Listing(ids: ["m"], complete: true))
        XCTAssertEqual(reconcile("TRASH", m), "INBOX")
        XCTAssertEqual(reconcile("SPAM UNREAD", m), "INBOX")
        // Holds even when the Trash and Spam listings were cut off.
        let cut = membership(trash: Listing(ids: [], complete: false),
                             spam: Listing(ids: [], complete: false))
        XCTAssertEqual(reconcile("Label_1 TRASH", cut), "Label_1")
    }

    func testRowInTrashOrSpamListingGainsItAndLosesInbox() {
        for (label, complete) in [("TRASH", true), ("TRASH", false),
                                  ("SPAM", true), ("SPAM", false)] {
            let listing = Listing(ids: ["m"], complete: complete)
            let m = label == "TRASH" ? membership(window: [], trash: listing)
                                     : membership(window: [], spam: listing)
            XCTAssertEqual(reconcile("INBOX Label_1", m), "Label_1 \(label)", label)
        }
    }

    /// The UNREAD and STARRED listings exclude Trash and Spam, so their
    /// silence about a trashed row is not evidence.
    func testTrashedRowKeepsUnreadAndStarred() {
        let m = membership(window: [], trash: Listing(ids: ["m"], complete: true))
        XCTAssertEqual(reconcile("INBOX STARRED UNREAD", m), "STARRED TRASH UNREAD")
    }

    /// Trashed between the window listing and the Trash listing: the later
    /// listing wins.
    func testTrashListingWinsOverWindowAndInboxListings() {
        let m = membership(window: ["m"],
                           inbox: Listing(ids: ["m"], complete: true),
                           trash: Listing(ids: ["m"], complete: true))
        XCTAssertEqual(reconcile("INBOX", m), "TRASH")
    }

    func testRowAbsentFromTrashListingButNotInWindowKeepsTrash() {
        // Not named by any listing: no evidence it left the Trash.
        XCTAssertEqual(reconcile("TRASH", membership(window: [])), "TRASH")
    }

    // MARK: - Output shape

    func testUnchangedRowReturnsTheSameString() {
        let m = membership(inbox: Listing(ids: ["m"], complete: true))
        // Unsorted and double-spaced on purpose: no rewrite without a change.
        XCTAssertEqual(reconcile("Label_9  INBOX", m), "Label_9  INBOX")
    }

    func testChangedRowIsSortedLikeHistoryDeltas() {
        let m = membership(unread: Listing(ids: ["m"], complete: true))
        XCTAssertEqual(reconcile("SENT Label_1 INBOX", m), "Label_1 SENT UNREAD")
        XCTAssertEqual(SyncEngine.applyLabelDelta(labelIds: "SENT Label_1 INBOX",
                                                  add: ["UNREAD"], remove: ["INBOX"]),
                       "Label_1 SENT UNREAD")
    }

    // MARK: - changes / refreshOrder

    private func row(_ gmailId: String, labels: String, daysAgo: Double,
                     thread: String? = nil) -> SystemLabelReconcile.Row {
        SystemLabelReconcile.Row(
            id: "\(account):\(gmailId)", gmailId: gmailId,
            threadId: "\(account):\(thread ?? "t-" + gmailId)", labelIds: labels,
            date: Date().addingTimeInterval(-daysAgo * 86_400))
    }

    func testChangesListsOnlyRowsThatDifferAndHonorsTheEdgeMargin() {
        let rows = [row("stale", labels: "INBOX UNREAD", daysAgo: 5),
                    row("fine", labels: "INBOX", daysAgo: 5),
                    row("edge", labels: "INBOX UNREAD", daysAgo: 89.5),
                    row("unlisted", labels: "INBOX UNREAD", daysAgo: 5)]
        let m = membership(window: ["stale", "fine", "edge"],
                           inbox: Listing(ids: ["fine"], complete: true))
        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        let changes = SystemLabelReconcile.changes(rows: rows, membership: m,
                                                   windowCutoff: cutoff)
        XCTAssertEqual(changes, [
            SystemLabelReconcile.Change(id: "\(account):stale",
                                        threadId: "\(account):t-stale",
                                        oldLabelIds: "INBOX UNREAD", newLabelIds: ""),
        ])
        // "Everything" has no edge.
        let all = SystemLabelReconcile.changes(rows: rows, membership: m, windowCutoff: nil)
        XCTAssertEqual(Set(all.map(\.id)), ["\(account):stale", "\(account):edge"])
    }

    func testRefreshOrderPutsUncoveredRowsFirstThenNewest() {
        let rows = [row("old", labels: "", daysAgo: 30),
                    row("new", labels: "", daysAgo: 1),
                    row("unlistedOld", labels: "", daysAgo: 40),
                    row("unlistedNew", labels: "", daysAgo: 2),
                    row("trashed", labels: "", daysAgo: 3)]
        let m = membership(window: ["old", "new"],
                           trash: Listing(ids: ["trashed"], complete: true))
        XCTAssertEqual(SystemLabelReconcile.refreshOrder(rows: rows, membership: m),
                       ["unlistedNew", "unlistedOld", "new", "trashed", "old"])
    }

    // MARK: - Database

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            for id in [account, other] {
                try Account(id: id, displayName: "P", historyId: nil,
                            lastSyncAt: nil, senderName: "").save(db)
            }
        }
        return q
    }

    private func insert(_ db: Database, account: String, gmailId: String, thread: String,
                        labels: String, daysAgo: Double = 5) throws {
        try Message(
            id: "\(account):\(gmailId)", accountId: account, gmailId: gmailId,
            threadId: "\(account):\(thread)", fromHeader: "Jane <jane@y.com>",
            toHeader: account, ccHeader: "", bccHeader: "", subject: "s",
            date: Date().addingTimeInterval(-daysAgo * 86_400),
            snippet: "", bodyText: "", bodyHTML: nil, messageIdHeader: "",
            referencesHeader: "", labelIds: labels,
            isUnread: labels.contains("UNREAD"), hasAttachment: false).save(db)
    }

    private func rows(_ db: Database, account: String) throws -> [SystemLabelReconcile.Row] {
        try Message.filter(Column("accountId") == account).fetchAll(db).map {
            SystemLabelReconcile.Row(id: $0.id, gmailId: $0.gmailId, threadId: $0.threadId,
                                     labelIds: $0.labelIds, date: $0.date)
        }
    }

    /// Seeds, reconciles, derives — the order the engine runs.
    private func reconcileDB(_ q: DatabaseQueue, _ m: Membership) throws -> Set<String> {
        try q.write { db in
            let changes = SystemLabelReconcile.changes(
                rows: try self.rows(db, account: self.account), membership: m,
                windowCutoff: Date().addingTimeInterval(-90 * 86_400))
            let keys = try SystemLabelReconcile.apply(db, accountId: self.account,
                                                      changes: changes)
            try SyncEngine.deriveThreads(db, for: keys, accountId: self.account)
            return keys
        }
    }

    func testReconcileCorrectsThreadRowsThroughDerive() throws {
        let q = try makeDB()
        try q.write { db in
            // Archived and read on the phone.
            try self.insert(db, account: account, gmailId: "a1", thread: "ta",
                            labels: "INBOX UNREAD")
            // Still in the inbox, read on the phone, starred on the phone.
            try self.insert(db, account: account, gmailId: "b1", thread: "tb",
                            labels: "INBOX UNREAD")
            // Trashed on the phone.
            try self.insert(db, account: account, gmailId: "c1", thread: "tc",
                            labels: "INBOX")
            // Unchanged.
            try self.insert(db, account: account, gmailId: "d1", thread: "td",
                            labels: "INBOX UNREAD Label_1")
            // Older than the window listing reaches: not covered.
            try self.insert(db, account: account, gmailId: "e1", thread: "te",
                            labels: "INBOX UNREAD")
            // Same Gmail id on another account.
            try self.insert(db, account: other, gmailId: "a1", thread: "ta",
                            labels: "INBOX UNREAD")
            for (acct, keys) in [(account, ["ta", "tb", "tc", "td", "te"]), (other, ["ta"])] {
                try SyncEngine.deriveThreads(
                    db, for: Set(keys.map { "\(acct):\($0)" }), accountId: acct)
            }
        }
        let m = membership(
            window: ["a1", "b1", "d1"],
            inbox: Listing(ids: ["b1", "d1"], complete: true),
            unread: Listing(ids: ["d1"], complete: true),
            starred: Listing(ids: ["b1"], complete: true),
            trash: Listing(ids: ["c1"], complete: true))
        let keys = try reconcileDB(q, m)
        XCTAssertEqual(keys, ["\(account):ta", "\(account):tb", "\(account):tc"])

        try q.read { db in
            func thread(_ key: String) throws -> MailThread {
                try XCTUnwrap(MailThread.fetchOne(db, key: key))
            }
            let a = try thread("\(account):ta")
            XCTAssertFalse(a.inInbox)
            XCTAssertFalse(a.isUnread)
            let b = try thread("\(account):tb")
            XCTAssertTrue(b.inInbox)
            XCTAssertFalse(b.isUnread)
            XCTAssertTrue(b.isStarred)
            let c = try thread("\(account):tc")
            XCTAssertTrue(c.inTrash)
            XCTAssertFalse(c.inInbox)
            let d = try thread("\(account):td")
            XCTAssertTrue(d.inInbox)
            XCTAssertTrue(d.isUnread)
            XCTAssertEqual(d.labelIds, "INBOX Label_1 UNREAD")
            let e = try thread("\(account):te")
            XCTAssertTrue(e.inInbox, "a row no listing names is not changed")
            XCTAssertTrue(e.isUnread)
            let theirs = try thread("\(other):ta")
            XCTAssertTrue(theirs.inInbox, "another account is not touched")
            XCTAssertTrue(theirs.isUnread)

            let msg = try XCTUnwrap(Message.fetchOne(db, key: "\(account):a1"))
            XCTAssertEqual(msg.labelIds, "")
            XCTAssertFalse(msg.isUnread, "the isUnread column follows the labels")
            XCTAssertEqual(try Message.fetchOne(db, key: "\(other):a1")?.labelIds,
                           "INBOX UNREAD")
        }
    }

    /// Truncated listings must leave a mailbox as cached.
    func testIncompleteListingsRemoveNothing() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insert(db, account: account, gmailId: "a1", thread: "ta",
                            labels: "INBOX STARRED UNREAD")
            try SyncEngine.deriveThreads(db, for: ["\(account):ta"], accountId: account)
        }
        let cut = Listing(ids: [], complete: false)
        let keys = try reconcileDB(q, membership(
            window: ["a1"], inbox: cut, unread: cut, starred: cut, trash: cut, spam: cut))
        XCTAssertTrue(keys.isEmpty)
        try q.read { db in
            XCTAssertEqual(try Message.fetchOne(db, key: "\(account):a1")?.labelIds,
                           "INBOX STARRED UNREAD")
        }
    }

    /// A queued offline edit is newer than anything Gmail listed; the
    /// thread must keep both its message rows and its optimistic thread row.
    func testThreadWithQueuedOfflineEditIsNotTouched() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insert(db, account: account, gmailId: "a1", thread: "ta",
                            labels: "INBOX UNREAD")
            try self.insert(db, account: account, gmailId: "b1", thread: "tb",
                            labels: "INBOX UNREAD")
            try SyncEngine.deriveThreads(
                db, for: ["\(account):ta", "\(account):tb"], accountId: account)
            // Starred offline: thread row only, plus the queue row.
            try db.execute(sql: "UPDATE thread SET isStarred = 1 WHERE id = ?",
                           arguments: ["\(account):ta"])
            try PendingThreadOp.enqueue(db, accountId: account, gmailThreadId: "ta",
                                        change: .modify(add: ["STARRED"]))
            // Another account's queue row for the same thread id is not ours.
            try PendingThreadOp.enqueue(db, accountId: other, gmailThreadId: "tb",
                                        change: .modify(add: ["STARRED"]))
        }
        let keys = try reconcileDB(q, membership(window: ["a1", "b1"]))
        XCTAssertEqual(keys, ["\(account):tb"])
        try q.read { db in
            XCTAssertEqual(try Message.fetchOne(db, key: "\(account):a1")?.labelIds,
                           "INBOX UNREAD")
            let a = try XCTUnwrap(MailThread.fetchOne(db, key: "\(account):ta"))
            XCTAssertTrue(a.isStarred, "the optimistic edit is still on screen")
            XCTAssertTrue(a.inInbox)
            let b = try XCTUnwrap(MailThread.fetchOne(db, key: "\(account):tb"))
            XCTAssertFalse(b.inInbox)
        }
    }

    /// A row that changed between the read and the write keeps the newer
    /// labels.
    func testRowChangedSinceTheReadIsNotOverwritten() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insert(db, account: account, gmailId: "a1", thread: "ta",
                            labels: "INBOX UNREAD")
        }
        let changes = try q.read { db in
            SystemLabelReconcile.changes(rows: try self.rows(db, account: account),
                                         membership: membership(window: ["a1"]),
                                         windowCutoff: nil)
        }
        XCTAssertEqual(changes.count, 1)
        let keys = try q.write { db -> Set<String> in
            try db.execute(sql: "UPDATE message SET labelIds = 'INBOX Label_7'")
            return try SystemLabelReconcile.apply(db, accountId: account, changes: changes)
        }
        XCTAssertTrue(keys.isEmpty)
        try q.read { db in
            XCTAssertEqual(try Message.fetchOne(db, key: "\(account):a1")?.labelIds,
                           "INBOX Label_7")
        }
    }
}
