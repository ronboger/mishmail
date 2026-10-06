import Foundation
import GRDB

/// Which unread inbox threads deserve a "new mail" notification.
///
/// Session state, keyed by thread id, holding the newest *inbound* message
/// date already accounted for. A plain id set could only grow: once a thread
/// had notified (or was unread at launch) a later reply in it stayed silent
/// for the rest of the session. Comparing dates lets that reply through while
/// a manual mark-unread — same date — stays quiet.
///
/// Pure so the rules are unit-tested; `MailStore.notifyNewMail` only reads
/// the rows and posts.
struct NewMailNotifications {
    /// The thread columns the decision needs. Property names match the
    /// `thread` columns so the call site can fetch this projection directly.
    struct Candidate: Equatable, Decodable, FetchableRecord {
        var id: String
        var fromEmail: String
        var allFromEmails: String
        var lastInboundDate: Date?
        var isUnread: Bool
        var inInbox: Bool
        var inTrash: Bool
        var inSpam: Bool
        var inPromotions: Bool
        var inSocial: Bool
        var snoozeUntil: Date?
    }

    /// False until the launch baseline (or the first sync pass, whichever
    /// comes first) has been adopted.
    private(set) var isSeeded = false
    private var knownInbound: [String: Date] = [:]

    /// Primary-tab unread only, awake. `unreadInboxCandidates` applies the
    /// same filter in SQL to keep the read narrow; this is the rule of record.
    static func isEligible(_ c: Candidate, now: Date) -> Bool {
        guard c.isUnread, c.inInbox, !c.inTrash, !c.inSpam,
              !c.inPromotions, !c.inSocial else { return false }
        if let until = c.snoozeUntil, until > now { return false }
        return true
    }

    /// Adopts `current` as already known, so none of it notifies.
    mutating func seed(_ current: [Candidate]) {
        for c in current { record(c) }
        isSeeded = true
    }

    /// Ids to notify for, in `current` order, and records them as known.
    ///
    /// Silent when: this is the first pass (it becomes the baseline), demo
    /// mode, the thread has no inbound message (own sent mail), the inbound
    /// date did not advance, or a blocked sender wrote in the thread. Silent
    /// passes still record what they saw, so unblocking a sender or leaving
    /// the demo does not replay old mail as new.
    mutating func fresh(current: [Candidate], now: Date, demoMode: Bool,
                        isBlocked: (String) -> Bool) -> [String] {
        guard isSeeded else {
            seed(current.filter { Self.isEligible($0, now: now) })
            return []
        }
        var ids: [String] = []
        for c in current where Self.isEligible(c, now: now) {
            guard let inbound = c.lastInboundDate else { continue }
            if let known = knownInbound[c.id], inbound <= known { continue }
            knownInbound[c.id] = inbound
            if demoMode || Self.hasBlockedSender(c, isBlocked: isBlocked) { continue }
            ids.append(c.id)
        }
        return ids
    }

    private mutating func record(_ c: Candidate) {
        // No inbound date: nothing to compare a later reply against, and the
        // first inbound message in the thread should notify.
        guard let inbound = c.lastInboundDate else { return }
        knownInbound[c.id] = max(knownInbound[c.id] ?? inbound, inbound)
    }

    /// Any-message match, like `MailStore.applyBlocklist`.
    private static func hasBlockedSender(_ c: Candidate,
                                         isBlocked: (String) -> Bool) -> Bool {
        if isBlocked(c.fromEmail) { return true }
        return c.allFromEmails.split(separator: " ").contains { isBlocked(String($0)) }
    }

    // MARK: - Read

    /// The current candidates. A narrow projection — `fetchAll()` of whole
    /// rows decoded every column of every unread inbox thread (participants,
    /// snippet, label blob) just to throw nearly all of it away. `select`
    /// pushes the projection into SQL, so SQLCipher only decrypts what the
    /// decision needs.
    static func unreadInboxCandidates(_ db: Database, now: Date) throws -> [Candidate] {
        // Primary-tab unread only. Starred promo/social can appear in the
        // inbox *list* (CategoryHide pin-through) but do not notify — a
        // star is a list pin, not a reclassification into Primary.
        // Match primary badge / inbox list: skip actively snoozed rows so
        // a sleeping unread does not notify or seed the baseline.
        try MailThread
            .filter(Column("isUnread") == true)
            .filter(Column("inInbox") == true)
            .filter(Column("inTrash") == false)
            .filter(Column("inSpam") == false)
            .filter(Column("inPromotions") == false)
            .filter(Column("inSocial") == false)
            .filter(Column("snoozeUntil") == nil || Column("snoozeUntil") <= now)
            .select(Column("id"), Column("fromEmail"), Column("allFromEmails"),
                    Column("lastInboundDate"), Column("isUnread"), Column("inInbox"),
                    Column("inTrash"), Column("inSpam"), Column("inPromotions"),
                    Column("inSocial"), Column("snoozeUntil"))
            .asRequest(of: Candidate.self)
            .fetchAll(db)
    }
}
