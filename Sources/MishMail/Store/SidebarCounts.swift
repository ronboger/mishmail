import Foundation
import GRDB

/// Sidebar unread / dock badge aggregates.
///
/// Extracted from `MailStore` so hostless unit tests share the exact SQL
/// (no AppKit). Prefer per-predicate `COUNT(*)` over a full-table
/// `SUM(CASE…)` so SQLite can use partial indexes from migration v21.
enum SidebarCounts {
    /// Gmail categories that have no dedicated sidebar tab. When the inbox
    /// filter hides them (`CategoryFilter.hide`), the primary unread badge
    /// must drop them too — otherwise the counter still looks like Updates
    /// (etc.) are in the list. Promo/Social always route to their own badges
    /// regardless of the hide set.
    static let primaryHideableCategories: Set<String> = [
        "CATEGORY_UPDATES",
        "CATEGORY_FORUMS",
    ]

    /// SQL AND-clause matching inbox list `notSnoozed`: no future snooze.
    /// Bind `now` as the sole argument for this fragment.
    static let notActivelySnoozedSQL =
        " AND (snoozeUntil IS NULL OR snoozeUntil <= ?)"

    /// True while the thread is sleeping (list-hidden from Inbox).
    static func isActivelySnoozed(_ thread: MailThread, now: Date = Date()) -> Bool {
        guard let until = thread.snoozeUntil else { return false }
        return until > now
    }

    /// In-memory counterpart of the SQL predicates below. Optimistic thread
    /// actions use this to keep sidebar badges in the same frame as the row;
    /// the coalesced database reconciliation remains the source of truth.
    ///
    /// `hideCategories` is the inbox "do not contain" set (Updates/Forums
    /// only affect the primary badge; promo/social always tab-split).
    /// Actively snoozed mail is list-hidden from Inbox/Promo/Social and must
    /// not inflate those unread badges (it still counts under Snoozed).
    static func memberships(
        of thread: MailThread,
        now: Date = Date(),
        hideCategories: Set<String> = []
    ) -> Set<String> {
        var result = Set<String>()
        let sleeping = isActivelySnoozed(thread, now: now)
        // Unread tab badges track the visible lists — not while snoozed.
        if thread.isUnread && !thread.inTrash && !thread.inSpam && thread.inInbox
            && !sleeping {
            if thread.inPromotions {
                result.insert("promotions")
            }
            if thread.inSocial {
                result.insert("social")
            }
            // Primary badge only — not starred pin-through. Starred promo/social
            // can show in the inbox list (CategoryHide) but still count under
            // their category tab, not the inbox unread badge. Hidden Updates/
            // Forums likewise stay out of the primary badge (no tab for them).
            if !thread.inPromotions && !thread.inSocial
                && !isHiddenFromPrimary(thread, hide: hideCategories) {
                result.insert("inbox")
            }
        }
        if thread.reminderAt != nil {
            result.insert("reminders")
        }
        if thread.isStarred && !thread.inTrash {
            result.insert("starred")
        }
        if sleeping && !thread.inTrash {
            result.insert("snoozed")
        }
        if thread.inDrafts && !thread.inTrash {
            result.insert("drafts")
        }
        return result
    }

    /// Whether a non-promo/non-social thread is excluded from the primary
    /// badge by the inbox category hide set.
    static func isHiddenFromPrimary(_ thread: MailThread, hide: Set<String>) -> Bool {
        let labels = Set(thread.labels)
        for cat in hide where primaryHideableCategories.contains(cat) {
            if labels.contains(cat) { return true }
        }
        return false
    }

    /// SQL fragment (AND-joined) excluding hideable categories present in
    /// `hide`. Empty when none apply. Uses the same `labelIds LIKE` token
    /// style as `CategoryHide` for Updates/Forums.
    static func primaryHideSQL(hide: Set<String>) -> String {
        var parts: [String] = []
        for cat in hide.sorted() where primaryHideableCategories.contains(cat) {
            // labelIds is space-separated; bound tokens are fixed Gmail ids
            // (not user text), so interpolating is safe and matches CategoryHide.
            parts.append("labelIds NOT LIKE '%\(cat)%'")
        }
        return parts.isEmpty ? "" : " AND " + parts.joined(separator: " AND ")
    }

    /// `activeAccount`/`badgeAccount` nil = every account.
    /// Safe off MainActor. Sole source of truth for sidebar unread — do not
    /// merge Gmail `labelInfo` / CATEGORY_* totals (those include spam +
    /// archived and disagree with list filters).
    ///
    /// `hideCategories` is the inbox category-hide set (typically from
    /// `FilterChips` for the inbox view). Promo/Social always stay out of
    /// the primary badge; Updates/Forums drop out only when hidden.
    static func fetch(
        db: Database,
        activeAccount: String?,
        badgeAccount: String?,
        now: Date = Date(),
        hideCategories: Set<String> = []
    ) throws -> (counts: [String: Int], badge: Int) {
        let hideSQL = primaryHideSQL(hide: hideCategories)
        // Not actively snoozed — same gate as inbox list `notSnoozed`. A reply
        // on a sleeping thread used to keep UNREAD+INBOX while list-hidden,
        // inflating the badge with nothing visible under is:unread.
        let awake = notActivelySnoozedSQL
        // Primary-tab unread only (matches memberships). Starred category mail
        // is list-pinned via CategoryHide but does not inflate this badge.
        let inbox = try count(db, account: activeAccount, where: """
            isUnread = 1 AND inTrash = 0 AND inSpam = 0 AND inInbox = 1
            AND inPromotions = 0 AND inSocial = 0\(hideSQL)\(awake)
            """, arguments: [now])
        let promotions = try count(db, account: activeAccount, where: """
            isUnread = 1 AND inTrash = 0 AND inSpam = 0 AND inInbox = 1
            AND inPromotions = 1\(awake)
            """, arguments: [now])
        let social = try count(db, account: activeAccount, where: """
            isUnread = 1 AND inTrash = 0 AND inSpam = 0 AND inInbox = 1
            AND inSocial = 1\(awake)
            """, arguments: [now])
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
                AND inPromotions = 0 AND inSocial = 0\(hideSQL)\(awake)
                """, arguments: [now])
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
