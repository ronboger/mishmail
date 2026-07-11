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
            messageCount: 1, hasAttachment: false, reminderAt: nil)
        let c = ThreadListPaging.nextCursor(after: [t])
        XCTAssertEqual(c?.id, "a:t1")
        XCTAssertEqual(c?.lastDate, t.lastDate)
        XCTAssertNil(ThreadListPaging.nextCursor(after: []))
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
