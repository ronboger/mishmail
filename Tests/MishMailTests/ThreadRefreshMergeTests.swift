import XCTest

/// The open reading pane refreshes in place when the store reloads
/// (`threadContentVersion`); this merge keeps hydrated bodies while taking
/// fresh header rows — and drops rows gone from the DB (discarded drafts).
final class ThreadRefreshMergeTests: XCTestCase {

    private func msg(id: String, labels: String = "INBOX",
                     bodyText: String = "", bodyHTML: String? = nil) -> Message {
        Message(
            id: "a:\(id)", accountId: "a", gmailId: id,
            threadId: "a:t1", fromHeader: "Ron <a@x.com>", toHeader: "b@x.com",
            ccHeader: "", bccHeader: "", subject: "Re: hi",
            date: Date(timeIntervalSince1970: 1_783_372_500),
            snippet: "", bodyText: bodyText, bodyHTML: bodyHTML,
            messageIdHeader: "<\(id)@mail>", referencesHeader: "",
            labelIds: labels, isUnread: false, hasAttachment: false)
    }

    func testDiscardedDraftDisappears() {
        let current = [
            msg(id: "1", bodyText: "hello"),
            msg(id: "d1", labels: "DRAFT", bodyText: "draft body"),
        ]
        let fresh = [msg(id: "1")] // draft row deleted by sync
        let merged = ThreadRefresh.merge(current: current, fresh: fresh)
        XCTAssertEqual(merged.map(\.gmailId), ["1"],
                       "discarded draft must leave the open thread on refresh")
    }

    func testHydratedBodySurvivesHeaderOnlyRefresh() {
        let current = [msg(id: "1", bodyText: "full body", bodyHTML: "<p>full</p>")]
        let fresh = [msg(id: "1")] // messageHeaders(inThread:) returns empty bodies
        let merged = ThreadRefresh.merge(current: current, fresh: fresh)
        XCTAssertEqual(merged[0].bodyText, "full body")
        XCTAssertEqual(merged[0].bodyHTML, "<p>full</p>")
    }

    func testFreshLabelsWinOverStaleCurrent() {
        let current = [msg(id: "1", labels: "INBOX UNREAD", bodyText: "body")]
        let fresh = [msg(id: "1", labels: "INBOX")]
        let merged = ThreadRefresh.merge(current: current, fresh: fresh)
        XCTAssertEqual(merged[0].labelIds, "INBOX",
                       "header fields must come from the fresh row")
        XCTAssertEqual(merged[0].bodyText, "body",
                       "while the hydrated body is spliced back in")
    }

    func testNewMessageArrivesHeaderOnly() {
        let current = [msg(id: "1", bodyText: "body")]
        let fresh = [msg(id: "1"), msg(id: "2")]
        let merged = ThreadRefresh.merge(current: current, fresh: fresh)
        XCTAssertEqual(merged.map(\.gmailId), ["1", "2"])
        XCTAssertTrue(ThreadRefresh.needsBodyLoad(merged[1]))
    }

    func testFreshBodyPreferredWhenPresent() {
        let current = [msg(id: "1", bodyText: "old")]
        let fresh = [msg(id: "1", bodyText: "new")]
        let merged = ThreadRefresh.merge(current: current, fresh: fresh)
        XCTAssertEqual(merged[0].bodyText, "new")
    }
}
