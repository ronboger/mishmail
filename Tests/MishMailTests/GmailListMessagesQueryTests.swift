import XCTest

/// `messages.list` skips TRASH and SPAM unless `includeSpamTrash=true`. The
/// history-expired reconcile lists both labels with a `newer_than` query; an
/// empty answer there deleted every cached trash and spam row.
final class GmailListMessagesQueryTests: XCTestCase {
    func testPlainListingOmitsIncludeSpamTrash() {
        let q = GmailClient.listMessagesQuery(
            query: "newer_than:90d", labelIds: ["INBOX"], pageToken: "p2",
            maxResults: 100, includeSpamTrash: false)
        XCTAssertEqual(q, ["maxResults": "100", "q": "newer_than:90d",
                           "labelIds": "INBOX", "pageToken": "p2"])
    }

    func testExplicitIncludeSpamTrash() {
        let q = GmailClient.listMessagesQuery(
            query: nil, labelIds: [], pageToken: nil, maxResults: 1, includeSpamTrash: true)
        XCTAssertEqual(q["includeSpamTrash"], "true")
    }

    func testTrashAndSpamLabelsAlwaysIncludeSpamTrash() {
        for label in ["TRASH", "SPAM"] {
            let q = GmailClient.listMessagesQuery(
                query: "newer_than:90d", labelIds: [label], pageToken: nil,
                maxResults: 100, includeSpamTrash: false)
            XCTAssertEqual(q["includeSpamTrash"], "true", label)
            XCTAssertEqual(q["labelIds"], label)
        }
    }
}
