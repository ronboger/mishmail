import XCTest

final class ThreadListPagingTests: XCTestCase {
    func testHasMore() {
        XCTAssertTrue(ThreadListPaging.hasMore(fetchedCount: 300))
        XCTAssertTrue(ThreadListPaging.hasMore(fetchedCount: 400))
        XCTAssertFalse(ThreadListPaging.hasMore(fetchedCount: 299))
        XCTAssertFalse(ThreadListPaging.hasMore(fetchedCount: 0))
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
