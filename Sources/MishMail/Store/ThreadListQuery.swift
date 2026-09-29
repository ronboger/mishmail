import Foundation
import GRDB

/// Base predicates and ORDER BY for the inbox-style thread lists (Inbox,
/// Promotions, Social, per-account inbox).
///
/// Extracted from `MailStore.baseQuery` so hostless unit tests run the exact
/// SQL the v42 sort indexes were built for — same pattern as `CategoryHide`
/// and `SidebarCounts`. `ThreadListIndexTests` runs EXPLAIN QUERY PLAN over
/// these requests; if a predicate here changes shape (a new column ahead of
/// the sort key, `== false` turned into a LIKE, …) that test shows whether
/// the list still walks an index or falls back to a temp B-tree sort.
enum ThreadListQuery {
    /// Hide threads that are snoozed into the future. The OR is not
    /// indexable; it is a residual filter applied to rows the index walks.
    static func notSnoozed(_ q: QueryInterfaceRequest<MailThread>,
                           now: Date) -> QueryInterfaceRequest<MailThread> {
        q.filter(Column("snoozeUntil") == nil || Column("snoozeUntil") <= now)
    }

    /// Unified inbox. Category filtering is layered on by the chips.
    static func inbox(now: Date = Date()) -> QueryInterfaceRequest<MailThread> {
        notSnoozed(MailThread.filter(Column("inInbox") == true && Column("inTrash") == false),
                   now: now)
    }

    /// One account's inbox (sidebar account row).
    static func accountInbox(_ accountId: String,
                             now: Date = Date()) -> QueryInterfaceRequest<MailThread> {
        notSnoozed(MailThread.filter(Column("accountId") == accountId
                                     && Column("inInbox") == true
                                     && Column("inTrash") == false),
                   now: now)
    }

    /// Match gmail.com's Promotions tab: in-inbox category mail, never spam.
    static func promotions() -> QueryInterfaceRequest<MailThread> {
        MailThread.filter(Column("inTrash") == false
                          && Column("inSpam") == false
                          && Column("inInbox") == true
                          && Column("inPromotions") == true)
    }

    static func social() -> QueryInterfaceRequest<MailThread> {
        MailThread.filter(Column("inTrash") == false
                          && Column("inSpam") == false
                          && Column("inInbox") == true
                          && Column("inSocial") == true)
    }

    /// `ORDER BY <sort key> DESC, id DESC` — the one ordering every paged
    /// list uses, so the cursor predicate (`ThreadListPaging.olderThanSQL`)
    /// and the index column order agree.
    static func orderSQL(inboundSort: Bool) -> String {
        "\(ThreadListPaging.sortDateSQL(inboundSort: inboundSort)) DESC, id DESC"
    }
}
