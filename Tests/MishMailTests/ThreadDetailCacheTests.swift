import XCTest

final class ThreadDetailCacheTests: XCTestCase {
    func testLRUEvictsLeastRecentlyUsed() {
        var cache = ThreadDetailLRU<Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        XCTAssertEqual(cache.value(for: "a"), 1) // a is now most recent

        cache.insert(3, for: "c")

        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.value(for: "a"), 1)
        XCTAssertEqual(cache.value(for: "c"), 3)
    }

    func testLRUReplacementDoesNotDuplicateOrder() {
        var cache = ThreadDetailLRU<Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "a")
        cache.insert(3, for: "b")

        XCTAssertEqual(cache.order, ["a", "b"])
        XCTAssertEqual(cache.value(for: "a"), 2)
    }

    func testDraftSuppressionDropsMessagesAndAttachmentsTogether() {
        let sent = fixtureMessage(id: "sent", labels: "INBOX")
        let draft = fixtureMessage(id: "draft", labels: "DRAFT")
        let payload = ThreadDetailPayload(
            messages: [sent, draft],
            attachmentsByMessageId: [
                "sent": [fixtureAttachment(messageId: "sent")],
                "draft": [fixtureAttachment(messageId: "draft")],
            ])

        let visible = payload.suppressingDrafts(["draft"])

        XCTAssertEqual(visible.messages.map(\.id), ["sent"])
        XCTAssertEqual(Set(visible.attachmentsByMessageId.keys), ["sent"])
    }

    private func fixtureMessage(id: String, labels: String) -> Message {
        Message(
            id: id, accountId: "me@example.com", gmailId: id, threadId: "thread",
            fromHeader: "A <a@example.com>", toHeader: "me@example.com",
            ccHeader: "", subject: "Subject", date: Date(), snippet: "",
            bodyText: "", bodyHTML: nil, messageIdHeader: "<\(id)>",
            referencesHeader: "", labelIds: labels, isUnread: false,
            hasAttachment: false)
    }

    private func fixtureAttachment(messageId: String) -> AttachmentRow {
        AttachmentRow(
            id: nil, messageId: messageId, gmailAttachmentId: "att",
            filename: "file.txt", mimeType: "text/plain", size: 1)
    }
}
