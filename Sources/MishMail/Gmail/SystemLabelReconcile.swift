import Foundation
import GRDB

/// Corrects INBOX / UNREAD / STARRED / TRASH / SPAM on cached message rows
/// from the id listings the history-expired reconcile already fetched.
///
/// History is gone, so there are no label deltas for what changed while the
/// Mac was away; the listings are the only cheap source of truth. A wrong
/// rule here corrupts labels for a whole mailbox, so every rule needs
/// positive evidence:
///
/// - A label is **added** when the message is in that label's listing.
/// - A label is **removed** only when that label's listing ran to its last
///   page, and the row is known to be inside what the listing covers.
/// - A row the sync-window listing did not name (and that is not listed
///   under TRASH or SPAM) is never changed.
///
/// The listings are read after the new history id, so anything that changes
/// during or after them is replayed by the next incremental pass. Label
/// deltas are idempotent set operations: the replay ends in Gmail's state
/// whatever this reconcile wrote first.
enum SystemLabelReconcile {
    /// One `messages.list` result for a single label.
    struct Listing: Sendable, Equatable {
        var ids: Set<String>
        /// The listing reached its last page. False when it stopped at a
        /// cap: absence from `ids` then proves nothing.
        var complete: Bool

        static let empty = Listing(ids: [], complete: false)
    }

    /// Everything the reconcile listed, by Gmail message id.
    struct Membership: Sendable {
        /// Ids named by the sync-window listing. That listing excludes
        /// TRASH and SPAM, so an id here was in neither when it was listed.
        var window: Set<String>
        var inbox: Listing
        var unread: Listing
        /// All-time (no window query); excludes TRASH and SPAM.
        var starred: Listing
        var trash: Listing
        var spam: Listing
    }

    /// A cached message row, as much as the reconcile reads of it.
    struct Row: Sendable, Equatable {
        var id: String
        var gmailId: String
        var threadId: String
        var labelIds: String
        var date: Date
    }

    /// A row whose labels differ from what the listings say.
    struct Change: Sendable, Equatable {
        var id: String
        var threadId: String
        /// What the row held when it was read; the write is skipped when
        /// the row no longer holds this.
        var oldLabelIds: String
        var newLabelIds: String
    }

    /// Margin kept clear of the window's old edge. The window listing and
    /// the label listings evaluate `newer_than` at different moments, so a
    /// message at the edge can be in the first and aged out of the second.
    static let windowEdgeMargin: TimeInterval = 86_400

    /// The space-separated `labelIds` a cached row should hold.
    ///
    /// `insideWindow`: the row is far enough inside the sync window that the
    /// windowed INBOX and UNREAD listings cover it. When false those two
    /// labels can still be added but are never removed.
    ///
    /// Returns `current` itself (same string) when nothing changes.
    /// Pure — unit-tested.
    static func reconciledLabelIds(current: String, gmailId: String,
                                   insideWindow: Bool,
                                   membership m: Membership) -> String {
        let original = Set(current.split(whereSeparator: \.isWhitespace).map(String.init))
        var labels = original

        let inTrash = m.trash.ids.contains(gmailId)
        let inSpam = m.spam.ids.contains(gmailId)
        if inTrash || inSpam {
            // Listed later than the window listing, so this wins over it.
            // Gmail drops INBOX when a message goes to Trash or Spam. The
            // UNREAD and STARRED listings exclude both, so they say nothing
            // about this row.
            if inTrash { labels.insert("TRASH") }
            if inSpam { labels.insert("SPAM") }
            labels.remove("INBOX")
        } else if m.window.contains(gmailId) {
            // The window listing excludes Trash and Spam: it was in neither.
            labels.remove("TRASH")
            labels.remove("SPAM")
            apply("INBOX", m.inbox, gmailId, mayRemove: insideWindow, to: &labels)
            apply("UNREAD", m.unread, gmailId, mayRemove: insideWindow, to: &labels)
            apply("STARRED", m.starred, gmailId, mayRemove: true, to: &labels)
        }

        guard labels != original else { return current }
        return labels.sorted().joined(separator: " ")
    }

    private static func apply(_ label: String, _ listing: Listing, _ gmailId: String,
                              mayRemove: Bool, to labels: inout Set<String>) {
        if listing.ids.contains(gmailId) {
            labels.insert(label)
        } else if listing.complete && mayRemove {
            labels.remove(label)
        }
    }

    /// True when the reconcile has evidence about this row: the window
    /// listing or the Trash / Spam listing named it.
    static func covers(gmailId: String, membership m: Membership) -> Bool {
        m.window.contains(gmailId) || m.trash.ids.contains(gmailId)
            || m.spam.ids.contains(gmailId)
    }

    /// The rows whose labels must change. `windowCutoff` is the oldest date
    /// the sync window keeps (nil = everything). Pure — unit-tested.
    static func changes(rows: [Row], membership: Membership,
                        windowCutoff: Date?) -> [Change] {
        let edge = windowCutoff.map { $0.addingTimeInterval(windowEdgeMargin) }
        return rows.compactMap { row in
            let insideWindow = edge.map { row.date >= $0 } ?? true
            let updated = reconciledLabelIds(
                current: row.labelIds, gmailId: row.gmailId,
                insideWindow: insideWindow, membership: membership)
            guard updated != row.labelIds else { return nil }
            return Change(id: row.id, threadId: row.threadId,
                          oldLabelIds: row.labelIds, newLabelIds: updated)
        }
    }

    /// Gmail ids for the capped metadata refresh, most useful first: rows
    /// the listings could not cover (their system labels are still as
    /// cached), then the rest, each newest first. Pure — unit-tested.
    static func refreshOrder(rows: [Row], membership: Membership) -> [String] {
        let newestFirst = rows.sorted {
            $0.date != $1.date ? $0.date > $1.date : $0.gmailId < $1.gmailId
        }
        let uncovered = newestFirst.filter { !covers(gmailId: $0.gmailId, membership: membership) }
        let covered = newestFirst.filter { covers(gmailId: $0.gmailId, membership: membership) }
        return (uncovered + covered).map(\.gmailId)
    }

    /// Writes `changes` to this account's message rows and returns the
    /// thread keys of the rows that changed, for the caller to re-derive.
    ///
    /// Skipped, and left exactly as cached:
    /// - a thread with a queued offline edit (`pendingThreadOp`): Gmail has
    ///   not seen that edit, so the listings describe the state before it,
    ///   and re-deriving the thread would undo the edit on screen;
    /// - a row whose labels changed since it was read.
    ///
    /// Call inside a write transaction. Exercised by the test suite.
    static func apply(_ db: Database, accountId: String,
                      changes: [Change]) throws -> Set<String> {
        guard !changes.isEmpty else { return [] }
        let queued = Set(try String.fetchAll(
            db, sql: "SELECT gmailThreadId FROM pendingThreadOp WHERE accountId = ?",
            arguments: [accountId]).map { "\(accountId):\($0)" })
        var keys = Set<String>()
        for change in changes where !queued.contains(change.threadId) {
            let isUnread = SyncEngine.labelIdsContain(change.newLabelIds, "UNREAD")
            try db.execute(sql: """
                UPDATE message SET labelIds = ?, isUnread = ?
                WHERE id = ? AND accountId = ? AND labelIds = ?
                """, arguments: [change.newLabelIds, isUnread, change.id,
                                 accountId, change.oldLabelIds])
            if db.changesCount > 0 { keys.insert(change.threadId) }
        }
        return keys
    }
}
