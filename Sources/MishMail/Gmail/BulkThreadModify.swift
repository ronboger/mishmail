import Foundation
import GRDB

/// Plans a multi-select label edit (archive, star, read, spam, snooze) as
/// Gmail `messages.batchModify` calls instead of one `threads.modify` per
/// thread. Pure over its inputs (plus a `Database` for the fact read) so the
/// test suite runs it without a network or a `MailStore`.
///
/// Why this is not a straight swap: `threads.modify` relabels every message
/// Gmail holds for the thread; `batchModify` relabels exactly the ids it is
/// given, and the only ids we have are the local `message` rows. Those are
/// not always the whole thread — the sync window (default 90 days) never
/// fetched older messages, and a thread that began before it can still carry
/// INBOX or UNREAD on one of them. Archiving only the recent half would leave
/// the conversation in Gmail's inbox while ours shows it archived, and no
/// history record would ever reconcile the two. So a thread batches only when
/// its local rows provably cover it (`isLocallyComplete`); every other thread
/// keeps the old per-thread path.
enum BulkThreadModify {
    /// The columns of one local message that the plan needs.
    struct MessageFacts: Equatable, Sendable {
        var gmailId: String
        var date: Date
        var labelIds: String
        var referencesHeader: String
        var subject: String
    }

    /// How much of the account's mail is stored locally.
    struct Coverage: Equatable, Sendable {
        /// `SyncEngine.syncWindowDays(for:)`: 0 = everything, `windowNothing`
        /// = nothing, otherwise the day count.
        var windowDays: Int
        /// The backfill for exactly this window has finished. A window that
        /// was just widened is still being fetched, so its older mail is not
        /// yet local.
        var backfilled: Bool
    }

    struct Target: Sendable {
        /// Local thread id (`<account>:<gmailThreadId>`).
        var threadId: String
        var accountId: String
        var add: [String]
        var remove: [String]
        var messages: [MessageFacts]
    }

    /// One `batchModify` call.
    struct Batch: Equatable, Sendable {
        var accountId: String
        var add: [String]
        var remove: [String]
        var messageIds: [String]
        /// Local thread ids whose every known message is in `messageIds`.
        /// A failure falls back per thread, so a thread is never split
        /// across two calls.
        var threadIds: [String]
    }

    struct Plan: Equatable, Sendable {
        var batches: [Batch] = []
        /// Local thread ids that stay on the per-thread `threads.modify` path.
        var fallbackThreadIds: [String] = []
    }

    /// Subjects that mark a message as a reply or forward. A thread whose
    /// oldest local message carries one likely started earlier than we can
    /// see (a client that sets In-Reply-To but not References).
    private static let replyPrefixes = ["re:", "fw:", "fwd:", "aw:", "sv:", "wg:", "antw:", "tr:", "rv:"]

    /// Whether the local rows are every message Gmail holds for the thread,
    /// so a `batchModify` over them lands exactly what `threads.modify` would.
    ///
    /// The rule is conservative on purpose — a false "no" costs 10 quota
    /// units and one round trip, a false "yes" leaves Gmail and the list
    /// disagreeing until a full resync:
    /// - Local coverage is contiguous in time from the window start to the
    ///   last sync (backfill lists everything newer than the window, history
    ///   adds the rest). Older mail is local only when starred.
    /// - So the thread is complete when its oldest local message is the
    ///   conversation root (no References, no reply prefix) and that root is
    ///   itself inside the window — every later message then is too.
    /// - Threads holding a draft stay out: a draft is not an ordinary message
    ///   to `batchModify`, and one rejected id fails the whole call.
    ///
    /// Messages Gmail received after the last sync are not local either. That
    /// race is accepted: the new message keeps its labels, which is what
    /// Gmail's own UI does when mail arrives after an action, and the next
    /// history pass shows it.
    static func isLocallyComplete(_ messages: [MessageFacts], coverage: Coverage,
                                  now: Date = Date()) -> Bool {
        guard coverage.backfilled, coverage.windowDays != SyncEngine.windowNothing else { return false }
        guard let root = messages.min(by: { $0.date < $1.date }) else { return false }
        if messages.contains(where: { hasLabel($0.labelIds, "DRAFT") }) { return false }
        guard root.referencesHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        let subject = root.subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if replyPrefixes.contains(where: { subject.hasPrefix($0) }) { return false }
        if coverage.windowDays > 0 {
            let windowStart = now.addingTimeInterval(-Double(coverage.windowDays) * 86_400)
            guard root.date >= windowStart else { return false }
        }
        return true
    }

    /// Group batchable threads per account and per identical (add, remove)
    /// label set, packing whole threads into calls of at most `maxIds` ids.
    ///
    /// Falls back per thread when: the edit is empty (the old path sends it
    /// as-is), the account's coverage is unknown, the thread is not locally
    /// complete, a single thread alone exceeds `maxIds`, or a group ends up
    /// with one thread (its `threads.modify` costs 10 units, a batch 50).
    /// Output keeps target order within each group.
    static func plan(_ targets: [Target], coverage: [String: Coverage],
                     now: Date = Date(),
                     maxIds: Int = GmailClient.batchModifyMaxIds) -> Plan {
        struct GroupKey: Hashable {
            var accountId: String
            var add: Set<String>
            var remove: Set<String>
        }
        var result = Plan()
        var order: [GroupKey] = []
        var groups: [GroupKey: [Target]] = [:]
        for target in targets {
            guard !(target.add.isEmpty && target.remove.isEmpty),
                  let cov = coverage[target.accountId],
                  isLocallyComplete(target.messages, coverage: cov, now: now),
                  target.messages.count <= maxIds
            else {
                result.fallbackThreadIds.append(target.threadId)
                continue
            }
            let key = GroupKey(accountId: target.accountId,
                               add: Set(target.add), remove: Set(target.remove))
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(target)
        }
        for key in order {
            let members = groups[key] ?? []
            guard members.count > 1 else {
                result.fallbackThreadIds += members.map(\.threadId)
                continue
            }
            let first = members[0]
            var chunks: [Batch] = []
            var current = Batch(accountId: key.accountId, add: first.add, remove: first.remove,
                                messageIds: [], threadIds: [])
            for member in members {
                if current.messageIds.count + member.messages.count > maxIds {
                    chunks.append(current)
                    current.messageIds = []
                    current.threadIds = []
                }
                current.messageIds += member.messages.map(\.gmailId)
                current.threadIds.append(member.threadId)
            }
            if !current.threadIds.isEmpty { chunks.append(current) }
            // A trailing chunk of one thread is still a batch here: the group
            // as a whole was worth batching, and splitting hairs over one
            // call's quota is not worth a second code path.
            result.batches += chunks
        }
        return result
    }

    /// Local message facts for many threads in one read, keyed by local
    /// thread id. The IN list is chunked to stay far below SQLite's
    /// host-parameter limit on a select-all of thousands of rows.
    static func messageFacts(_ db: Database, threadIds: [String]) throws -> [String: [MessageFacts]] {
        var out: [String: [MessageFacts]] = [:]
        let unique = Array(Set(threadIds))
        var start = 0
        while start < unique.count {
            let end = min(start + 500, unique.count)
            let chunk = Array(unique[start..<end])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT threadId, gmailId, date, labelIds, referencesHeader, subject
                FROM message WHERE threadId IN (\(marks))
                """, arguments: StatementArguments(chunk))
            for row in rows {
                let threadId: String = row["threadId"]
                out[threadId, default: []].append(MessageFacts(
                    gmailId: row["gmailId"], date: row["date"], labelIds: row["labelIds"],
                    referencesHeader: row["referencesHeader"], subject: row["subject"]))
            }
            start = end
        }
        return out
    }

    /// Local ids of threads with a queued offline edit. Those must keep
    /// queueing (replay order matters), exactly as the per-thread path does.
    static func queuedThreadIds(_ db: Database) throws -> Set<String> {
        let rows = try PendingThreadOp.fetchAll(db)
        return Set(rows.map { "\($0.accountId):\($0.gmailThreadId)" })
    }

    /// Coverage from the same defaults keys `SyncEngine` writes. The
    /// `backfill.window.<account>` key is set only after the backfill for
    /// that window finished; an absent key means no finished backfill (read
    /// as an optional so "absent" is not mistaken for 0 = everything).
    static func coverage(for accountId: String) -> Coverage {
        let days = SyncEngine.syncWindowDays(for: accountId)
        let done = UserDefaults.standard.object(forKey: "backfill.window.\(accountId)") as? Int
        return Coverage(windowDays: days, backfilled: done == days)
    }

    private static func hasLabel(_ labelIds: String, _ label: String) -> Bool {
        labelIds.split(separator: " ").contains { $0 == label }
    }
}
