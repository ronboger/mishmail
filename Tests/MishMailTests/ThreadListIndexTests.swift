import XCTest
import GRDB

/// The inbox-style lists (Inbox, Promotions, Social, per-account inbox) sort
/// by `COALESCE(lastInboundDate, lastDate) DESC, id DESC`. Migration v42 adds
/// expression indexes that end in that exact key so SQLite can walk rows in
/// order and stop after one page, instead of sorting every match in a temp
/// B-tree first.
///
/// SQLite only uses an expression index when the query's expression matches
/// the index's, and only uses the index for ORDER BY when every column ahead
/// of the sort key is pinned by an equality. Both are easy to break silently
/// (reword `sortDateSQL`, add a chip that turns an equality into an OR), so
/// these tests run EXPLAIN QUERY PLAN on the production requests
/// (`ThreadListQuery` + `CategoryHide` + `ThreadListQuery.orderSQL`) against
/// a fully migrated database.
final class ThreadListIndexTests: XCTestCase {

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        return q
    }

    /// EXPLAIN QUERY PLAN detail lines for a request, joined for messages.
    private func plan<T>(_ db: Database, _ request: QueryInterfaceRequest<T>) throws -> String {
        let prepared = try request.makePreparedRequest(db, forSingleResult: false)
        let sql = prepared.statement.sql
        let rows = try Row.fetchAll(
            db, sql: "EXPLAIN QUERY PLAN " + sql,
            arguments: prepared.statement.arguments)
        let detail = rows.map { $0["detail"] as String }.joined(separator: " | ")
        return "\(detail)\n  SQL: \(sql)"
    }

    /// Mirrors `FilterChips.defaults(for: .inbox)` (hide Promotions and
    /// Social; starred pins through) — FilterChips itself is app-only.
    private func withDefaultInboxChips(
        _ q: QueryInterfaceRequest<MailThread>
    ) -> QueryInterfaceRequest<MailThread> {
        CategoryHide.apply(q, hide: ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL"])
    }

    private func page(_ q: QueryInterfaceRequest<MailThread>) -> QueryInterfaceRequest<MailThread> {
        q.order(sql: ThreadListQuery.orderSQL(inboundSort: true))
            .limit(ThreadListPaging.probeLimit())
    }

    private func assertIndexedOrder(_ plan: String, index: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(plan.contains("USE TEMP B-TREE FOR ORDER BY"),
                       "list query sorts in a temp B-tree: \(plan)", file: file, line: line)
        XCTAssertTrue(plan.contains(index),
                      "expected index \(index): \(plan)", file: file, line: line)
    }

    func testInboxFirstPageWalksSortIndex() throws {
        try makeDB().read { db in
            let p = try plan(db, page(withDefaultInboxChips(ThreadListQuery.inbox())))
            assertIndexedOrder(p, index: "thread_inbox_sort")
        }
    }

    /// Load older adds the cursor predicate on the same sort key.
    func testInboxLoadOlderWalksSortIndex() throws {
        try makeDB().read { db in
            let q = withDefaultInboxChips(ThreadListQuery.inbox())
                .filter(sql: ThreadListPaging.olderThanSQL(inboundSort: true),
                        arguments: [Date(), Date(), "a:x"])
            let p = try plan(db, page(q))
            assertIndexedOrder(p, index: "_sort")
        }
    }

    /// Unified inbox with one account selected, and the per-account inbox.
    func testAccountScopedInboxWalksAccountSortIndex() throws {
        try makeDB().read { db in
            let scoped = withDefaultInboxChips(ThreadListQuery.inbox())
                .filter(Column("accountId") == "a@x.com")
            assertIndexedOrder(try plan(db, page(scoped)), index: "_sort")
            let account = withDefaultInboxChips(ThreadListQuery.accountInbox("a@x.com"))
            assertIndexedOrder(try plan(db, page(account)), index: "thread_account_inbox_sort")
        }
    }

    func testPromotionsAndSocialWalkSortIndexes() throws {
        try makeDB().read { db in
            assertIndexedOrder(try plan(db, page(ThreadListQuery.promotions())),
                               index: "thread_promotions_sort")
            assertIndexedOrder(try plan(db, page(ThreadListQuery.social())),
                               index: "thread_social_sort")
        }
    }

    /// Thread open / sync derive: `WHERE threadId = ? ORDER BY date`.
    func testMessagesInThreadReadInDateOrder() throws {
        try makeDB().read { db in
            let q = Message.filter(Column("threadId") == "a:t").order(Column("date"))
            let p = try plan(db, q)
            assertIndexedOrder(p, index: "message_on_threadId_date")
            let desc = Message.filter(Column("threadId") == "a:t").order(Column("date").desc)
            assertIndexedOrder(try plan(db, desc), index: "message_on_threadId_date")
        }
    }
}
