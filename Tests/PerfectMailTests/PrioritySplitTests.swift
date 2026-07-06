import XCTest

final class PrioritySplitTests: XCTestCase {
    private func thread(_ id: String, starred: Bool = false,
                        labels: String = "INBOX") -> MailThread {
        MailThread(id: "a@x.com:\(id)", accountId: "a@x.com", gmailThreadId: id,
                   subject: "s", snippet: "sn", fromDisplay: "F",
                   lastDate: Date(timeIntervalSince1970: 1000),
                   isUnread: false, isStarred: starred, inInbox: true,
                   inTrash: false, labelIds: labels, snoozeUntil: nil,
                   participants: "F", messageCount: 1, hasAttachment: false,
                   reminderAt: nil)
    }

    func testStarredImportantModeTakesBoth() {
        let threads = [thread("t1", starred: true),
                       thread("t2", labels: "INBOX IMPORTANT"),
                       thread("t3")]
        let (priority, rest) = PrioritySplit.partition(threads, mode: .starredImportant)
        XCTAssertEqual(priority.map(\.gmailThreadId), ["t1", "t2"])
        XCTAssertEqual(rest.map(\.gmailThreadId), ["t3"])
    }

    func testStarredModeIgnoresImportant() {
        let threads = [thread("t1", starred: true),
                       thread("t2", labels: "INBOX IMPORTANT"),
                       thread("t3")]
        let (priority, rest) = PrioritySplit.partition(threads, mode: .starred)
        XCTAssertEqual(priority.map(\.gmailThreadId), ["t1"])
        XCTAssertEqual(rest.map(\.gmailThreadId), ["t2", "t3"])
    }

    func testOrderPreservedAndNoDuplication() {
        let threads = [thread("t1"), thread("t2", starred: true, labels: "INBOX IMPORTANT"),
                       thread("t3"), thread("t4", starred: true)]
        let (priority, rest) = PrioritySplit.partition(threads, mode: .starredImportant)
        XCTAssertEqual(priority.map(\.gmailThreadId), ["t2", "t4"])
        XCTAssertEqual(rest.map(\.gmailThreadId), ["t1", "t3"])
        XCTAssertEqual(priority.count + rest.count, threads.count)
    }

    func testOffPassesEverythingThrough() {
        let threads = [thread("t1", starred: true), thread("t2")]
        let (priority, rest) = PrioritySplit.partition(threads, mode: .off)
        XCTAssertTrue(priority.isEmpty)
        XCTAssertEqual(rest.map(\.gmailThreadId), ["t1", "t2"])
    }

    func testVIPThreadPinsInAnyActiveMode() {
        let threads = [thread("t1"), thread("t2")]
        for mode in [PrioritySplit.Mode.starred, .starredImportant] {
            let (priority, rest) = PrioritySplit.partition(
                threads, mode: mode, vipThreadIds: ["a@x.com:t2"])
            XCTAssertEqual(priority.map(\.gmailThreadId), ["t2"], "mode \(mode)")
            XCTAssertEqual(rest.map(\.gmailThreadId), ["t1"], "mode \(mode)")
        }
    }

    func testVIPIgnoredWhenOff() {
        let threads = [thread("t1")]
        let (priority, _) = PrioritySplit.partition(
            threads, mode: .off, vipThreadIds: ["a@x.com:t1"])
        XCTAssertTrue(priority.isEmpty)
    }

    func testImportantSubstringLabelDoesNotMatch() {
        // "UNIMPORTANT" or a user label containing the word must not qualify.
        let threads = [thread("t1", labels: "INBOX Label_UNIMPORTANT")]
        let (priority, _) = PrioritySplit.partition(threads, mode: .starredImportant)
        XCTAssertTrue(priority.isEmpty)
    }
}
