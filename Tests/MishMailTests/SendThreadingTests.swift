import XCTest

final class SendThreadingTests: XCTestCase {

    private let gmail = "ronboger@gmail.com"
    private let custom = "ron@ronboger.com"

    func testApiThreadIdExtractsBareIdForOwningAccount() {
        let local = "\(gmail):18abcDef"
        XCTAssertEqual(
            SendThreading.apiThreadId(localThreadId: local, apiAccountId: gmail),
            "18abcDef")
    }

    func testApiThreadIdIsCaseInsensitiveOnAccountPrefix() {
        let local = "\(gmail.uppercased()):deadbeef"
        XCTAssertEqual(
            SendThreading.apiThreadId(localThreadId: local, apiAccountId: gmail),
            "deadbeef")
    }

    func testApiThreadIdRejectsForeignAccountComposite() {
        // Multi-account bug: thread owned by gmail, API mailbox is custom.
        let foreign = "\(gmail):18abc"
        XCTAssertNil(
            SendThreading.apiThreadId(localThreadId: foreign, apiAccountId: custom),
            "must not pass a foreign mailbox's threadId (Gmail 404)")
    }

    func testApiThreadIdRejectsEmptyBareAfterPrefix() {
        XCTAssertNil(
            SendThreading.apiThreadId(localThreadId: "\(gmail):", apiAccountId: gmail))
        XCTAssertNil(
            SendThreading.apiThreadId(localThreadId: "\(gmail):   ", apiAccountId: gmail))
    }

    func testApiThreadIdRejectsNilAndBlank() {
        XCTAssertNil(SendThreading.apiThreadId(localThreadId: nil, apiAccountId: gmail))
        XCTAssertNil(SendThreading.apiThreadId(localThreadId: "", apiAccountId: gmail))
        XCTAssertNil(SendThreading.apiThreadId(localThreadId: "  ", apiAccountId: gmail))
        XCTAssertNil(SendThreading.apiThreadId(localThreadId: "\(gmail):x", apiAccountId: ""))
    }

    func testApiThreadIdAcceptsAlreadyBareId() {
        XCTAssertEqual(
            SendThreading.apiThreadId(localThreadId: "18f00", apiAccountId: gmail),
            "18f00")
    }

    func testApiThreadIdRejectsOtherCompositeWithoutMatchingPrefix() {
        // Looks like another account's composite, not a bare hex id.
        XCTAssertNil(
            SendThreading.apiThreadId(localThreadId: "other@x.com:18f00", apiAccountId: gmail))
    }

    func testLocalThreadIdPrefersReplyOverDraft() {
        XCTAssertEqual(
            SendThreading.localThreadId(replyThreadId: "a:t1", draftThreadId: "a:t2"),
            "a:t1")
        XCTAssertEqual(
            SendThreading.localThreadId(replyThreadId: nil, draftThreadId: "a:t2"),
            "a:t2")
        XCTAssertNil(
            SendThreading.localThreadId(replyThreadId: nil, draftThreadId: nil))
    }

    func testIsNotFoundDetectsGmail404Only() {
        XCTAssertTrue(SendThreading.isNotFound(GmailError.http(404, #"{"error":{"code":404}}"#)))
        XCTAssertFalse(SendThreading.isNotFound(GmailError.http(400, "bad request")))
        XCTAssertFalse(SendThreading.isNotFound(GmailError.http(500, "boom")))
        XCTAssertFalse(SendThreading.isNotFound(GmailError.historyExpired))
        XCTAssertFalse(SendThreading.isNotFound(URLError(.notConnectedToInternet)))
    }
}
