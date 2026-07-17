import XCTest

final class PendingDraftVisibilityTests: XCTestCase {
    private func message(_ id: String, labels: String) -> Message {
        Message(
            id: "a:\(id)", accountId: "a", gmailId: id, threadId: "a:t",
            fromHeader: "a@x.com", toHeader: "b@x.com", ccHeader: "",
            bccHeader: "", subject: "", date: Date(), snippet: "",
            bodyText: "", bodyHTML: nil, messageIdHeader: "",
            referencesHeader: "", labelIds: labels, isUnread: false,
            hasAttachment: false)
    }

    func testSuppressesOnlyPendingDraft() {
        let sent = message("sent", labels: "INBOX")
        let pending = message("draft-1", labels: "DRAFT")
        let otherDraft = message("draft-2", labels: "DRAFT")

        let visible = PendingDraftVisibility.visibleMessages(
            [sent, pending, otherDraft],
            suppressing: [pending.id])

        XCTAssertEqual(visible.map(\.id), [sent.id, otherDraft.id])
    }

    func testEmptySuppressionPreservesOrder() {
        let first = message("1", labels: "INBOX")
        let second = message("2", labels: "DRAFT")
        XCTAssertEqual(
            PendingDraftVisibility.visibleMessages([first, second], suppressing: []),
            [first, second])
    }
}
