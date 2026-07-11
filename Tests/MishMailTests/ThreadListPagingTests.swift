import XCTest

final class ThreadListPagingTests: XCTestCase {
    func testHasMore() {
        XCTAssertTrue(ThreadListPaging.hasMore(fetchedCount: 100))
        XCTAssertTrue(ThreadListPaging.hasMore(fetchedCount: 150))
        XCTAssertFalse(ThreadListPaging.hasMore(fetchedCount: 99))
        XCTAssertFalse(ThreadListPaging.hasMore(fetchedCount: 0))
        // Expanded window: full page at that depth still means "maybe more".
        XCTAssertTrue(ThreadListPaging.hasMore(fetchedCount: 200, pageSize: 200))
        XCTAssertFalse(ThreadListPaging.hasMore(fetchedCount: 150, pageSize: 200))
    }

    func testSplitPageUsesProbeRow() {
        let mk: (String) -> MailThread = { id in
            MailThread(
                id: id, accountId: "a", gmailThreadId: id,
                subject: "s", snippet: "", fromDisplay: "F",
                lastDate: Date(), isUnread: false, isStarred: false,
                inInbox: true, inTrash: false, labelIds: "INBOX",
                snoozeUntil: nil, participants: "F", messageCount: 1,
                hasAttachment: false, reminderAt: nil)
        }
        let rows = (0..<5).map { mk("t\($0)") }
        let (page, more) = ThreadListPaging.splitPage(rows, pageSize: 4)
        XCTAssertEqual(page.count, 4)
        XCTAssertTrue(more)
        let (exact, noMore) = ThreadListPaging.splitPage(Array(rows.prefix(4)), pageSize: 4)
        XCTAssertEqual(exact.count, 4)
        XCTAssertFalse(noMore, "exact pageSize without probe row → no more")
        XCTAssertEqual(ThreadListPaging.probeLimit(pageSize: 100), 101)
    }

    func testNextCursorFromLast() {
        let t = MailThread(
            id: "a:t1", accountId: "a", gmailThreadId: "t1",
            subject: "s", snippet: "", fromDisplay: "F",
            lastDate: Date(timeIntervalSince1970: 1000),
            isUnread: false, isStarred: false, inInbox: true, inTrash: false,
            labelIds: "INBOX", snoozeUntil: nil, participants: "F",
            messageCount: 1, hasAttachment: false, reminderAt: nil,
            lastInboundDate: Date(timeIntervalSince1970: 500))
        let c = ThreadListPaging.nextCursor(after: [t])
        XCTAssertEqual(c?.id, "a:t1")
        XCTAssertEqual(c?.sortDate, t.lastDate)
        let inbound = ThreadListPaging.nextCursor(after: [t], inboundSort: true)
        XCTAssertEqual(inbound?.sortDate, t.lastInboundDate)
        XCTAssertNil(ThreadListPaging.nextCursor(after: []))
    }

    func testOlderThanSQLSwitchesKey() {
        XCTAssertTrue(ThreadListPaging.olderThanSQL().contains("lastDate"))
        XCTAssertFalse(ThreadListPaging.olderThanSQL().contains("COALESCE"))
        XCTAssertTrue(ThreadListPaging.olderThanSQL(inboundSort: true)
            .contains("COALESCE(lastInboundDate, lastDate)"))
    }

    func testActivityDatePrefersInboundWhenAsked() {
        let t = MailThread(
            id: "a:t1", accountId: "a", gmailThreadId: "t1",
            subject: "s", snippet: "me: follow up", fromDisplay: "me",
            lastDate: Date(timeIntervalSince1970: 2_000),
            isUnread: false, isStarred: false, inInbox: true, inTrash: false,
            labelIds: "INBOX SENT", snoozeUntil: nil, participants: "Jane .. me",
            messageCount: 2, hasAttachment: false, reminderAt: nil,
            lastInboundDate: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(ThreadListPaging.activityDate(of: t, inboundSort: false), t.lastDate)
        XCTAssertEqual(ThreadListPaging.activityDate(of: t, inboundSort: true), t.lastInboundDate)
    }

    /// Headline contract: after you reply, the thread must not jump into the
    /// "Today" date section in the default Group by Date view.
    func testJustRepliedThreadStaysOutOfTodayWhenGroupingByInbound() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        // "Now" = 2026-07-11 12:00 UTC.
        let now = Date(timeIntervalSince1970: 1_783_771_200)
        let fiveDaysAgo = now.addingTimeInterval(-5 * 86_400)

        let justReplied = MailThread(
            id: "a:t1", accountId: "a", gmailThreadId: "t1",
            subject: "deal", snippet: "let's close?", fromDisplay: "me",
            lastDate: now,  // your reply is newest
            isUnread: false, isStarred: false, inInbox: true, inTrash: false,
            labelIds: "INBOX SENT", snoozeUntil: nil, participants: "Yaniv .. me",
            messageCount: 4, hasAttachment: false, reminderAt: nil,
            lastInboundDate: fiveDaysAgo)  // their last mail still older

        // Inbox-style: activity date is inbound → not Today.
        let inboundGroups = ThreadDateSections.group(
            [justReplied],
            dateKey: { ThreadListPaging.activityDate(of: $0, inboundSort: true) },
            now: now, calendar: cal)
        XCTAssertEqual(inboundGroups.map(\.0), ["Last 7 days"])
        XCTAssertFalse(inboundGroups.contains { $0.0 == "Today" })

        // Non-inbox (e.g. Sent): still buckets by newest → Today is correct.
        let sentGroups = ThreadDateSections.group(
            [justReplied],
            dateKey: { ThreadListPaging.activityDate(of: $0, inboundSort: false) },
            now: now, calendar: cal)
        XCTAssertEqual(sentGroups.map(\.0), ["Today"])
    }

    func testNeighborPrefetch() {
        let order = ["a", "b", "c"]
        let mid = NeighborPrefetch.neighbors(selected: "b", in: order)
        XCTAssertEqual(mid.prev, "a")
        XCTAssertEqual(mid.next, "c")
        let first = NeighborPrefetch.neighbors(selected: "a", in: order)
        XCTAssertNil(first.prev)
        XCTAssertEqual(first.next, "b")
        let miss = NeighborPrefetch.neighbors(selected: "z", in: order)
        XCTAssertNil(miss.prev)
        XCTAssertNil(miss.next)
    }
}
