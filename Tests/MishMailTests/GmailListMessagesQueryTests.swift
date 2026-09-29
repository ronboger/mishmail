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

    /// Capped paging loops take Gmail's max page but never list past `limit`.
    func testListPageSizeUsesMaxButNeverOvershootsLimit() {
        XCTAssertEqual(GmailClient.maxListPageSize, 500)
        XCTAssertEqual(SyncEngine.listPageSize(listed: 0, limit: 3_000), 500)
        XCTAssertEqual(SyncEngine.listPageSize(listed: 2_900, limit: 3_000), 100)
        XCTAssertEqual(SyncEngine.listPageSize(listed: 0, limit: 40), 40)
        XCTAssertEqual(SyncEngine.listPageSize(listed: 0, limit: .max), 500)
        XCTAssertEqual(SyncEngine.listPageSize(listed: 3_000, limit: 3_000), 1)
    }
}
