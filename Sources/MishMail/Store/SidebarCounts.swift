import Foundation
import GRDB

/// Sidebar unread / dock badge aggregates.
///
/// Extracted from `MailStore` so hostless unit tests share the exact SQL
/// (no AppKit). Prefer per-predicate `COUNT(*)` over a full-table
/// `SUM(CASE…)` so SQLite can use partial indexes from migration v21.
enum SidebarCounts {
    /// In-memory counterpart of the SQL predicates below. Optimistic thread
    /// actions use this to keep sidebar badges in the same frame as the row;
    /// the coalesced database reconciliation remains the source of truth.
    static func memberships(of thread: MailThread, now: Date = Date()) -> Set<String> {
        var result = Set<String>()
        if thread.isUnread && !thread.inTrash && !thread.inSpam && thread.inInbox {
            if thread.inPromotions {
                result.insert("promotions")
            }
            if thread.inSocial {
                result.insert("social")
            }
            if !thread.inPromotions && !thread.inSocial {
                result.insert("inbox")
            }
        }
        if thread.reminderAt != nil {
            result.insert("reminders")
        }
        if thread.isStarred && !thread.inTrash {
            result.insert("starred")
        }
        if let until = thread.snoozeUntil, until > now, !thread.inTrash {
            result.insert("snoozed")
        }
        if thread.inDrafts && !thread.inTrash {
            result.insert("drafts")
        }
        return result
    }

    /// `activeAccount`/`badgeAccount` nil = every account.
    /// Safe off MainActor. Sole source of truth for sidebar unread — do not
    /// merge Gmail `labelInfo` / CATEGORY_* totals (those include spam +
    /// archived and disagree with list filters).
    static func fetch(
        db: Database,
        activeAccount: String?,
        badgeAccount: String?,
        now: Date = Date()
    ) throws -> (counts: [String: Int], badge: Int) {
        let inbox = try count(db, account: activeAccount, where: """
            isUnread = 1 AND inTrash = 0 AND inSpam = 0 AND inInbox = 1
            AND inPromotions = 0 AND inSocial = 0
            """)
        let promotions = try count(db, account: activeAccount, where: """
            isUnread = 1 AND inTrash = 0 AND inSpam = 0 AND inInbox = 1
            AND inPromotions = 1
            """)
        let social = try count(db, account: activeAccount, where: """
            isUnread = 1 AND inTrash = 0 AND inSpam = 0 AND inInbox = 1
            AND inSocial = 1
            """)
        let reminders = try count(db, account: activeAccount, where: """
            reminderAt IS NOT NULL
            """)
        let starred = try count(db, account: activeAccount, where: """
            isStarred = 1 AND inTrash = 0
            """)
        let snoozed = try count(db, account: activeAccount, where: """
            snoozeUntil IS NOT NULL AND snoozeUntil > ? AND inTrash = 0
            """, arguments: [now])
        let drafts = try count(db, account: activeAccount, where: """
            inDrafts = 1 AND inTrash = 0
            """)

        // Dock badge uses the same primary-inbox predicate as `inbox`, but
        // may scope to a different account. Reuse when scopes match.
        let badge: Int
        if badgeAccount == activeAccount {
            badge = inbox
        } else {
            badge = try count(db, account: badgeAccount, where: """
                isUnread = 1 AND inTrash = 0 AND inSpam = 0 AND inInbox = 1
                AND inPromotions = 0 AND inSocial = 0
                """)
        }

        return ([
            "inbox": inbox,
            "promotions": promotions,
            "social": social,
            "reminders": reminders,
            "starred": starred,
            "snoozed": snoozed,
            "drafts": drafts,
        ], badge)
    }

    /// `COUNT(*)` with optional account scope. `where` is raw SQL predicates
    /// only (no user text) — arguments bind separately.
    private static func count(
        _ db: Database,
        account: String?,
        where predicate: String,
        arguments: [any DatabaseValueConvertible] = []
    ) throws -> Int {
        if let account {
            return try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM thread WHERE accountId = ? AND (\(predicate))",
                arguments: StatementArguments([account] + arguments)
            ) ?? 0
        }
        return try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM thread WHERE (\(predicate))",
            arguments: StatementArguments(arguments)
        ) ?? 0
    }
}
