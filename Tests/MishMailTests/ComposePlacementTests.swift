import XCTest

final class ComposePlacementTests: XCTestCase {
    private func message(threadId: String = "a:t1") -> Message {
        Message(
            id: "a:m1", accountId: "a", gmailId: "m1", threadId: threadId,
            fromHeader: "x@y.com", toHeader: "me@a.com", ccHeader: "",
            subject: "Hi", date: Date(), snippet: "", bodyText: "body",
            bodyHTML: nil, messageIdHeader: "<1>", referencesHeader: "",
            labelIds: "INBOX", isUnread: false, hasAttachment: false)
    }

    func testReplyToOpenThreadIsInline() {
        let msg = message()
        XCTAssertEqual(
            ComposePlacement.preferred(
                replyTo: msg, forward: false,
                selectedThreadId: msg.threadId, readingPaneHidden: false),
            .inline)
    }

    func testReplyWithHiddenPaneIsFloating() {
        let msg = message()
        XCTAssertEqual(
            ComposePlacement.preferred(
                replyTo: msg, forward: false,
                selectedThreadId: msg.threadId, readingPaneHidden: true),
            .floating)
    }

    func testForwardIsAlwaysFloating() {
        let msg = message()
        XCTAssertEqual(
            ComposePlacement.preferred(
                replyTo: msg, forward: true,
                selectedThreadId: msg.threadId, readingPaneHidden: false),
            .floating)
    }

    func testNewComposeIsFloating() {
        XCTAssertEqual(
            ComposePlacement.preferred(
                replyTo: nil, forward: false,
                selectedThreadId: "a:t1", readingPaneHidden: false),
            .floating)
    }

    func testEditDraftInOpenThreadIsInline() {
        var draft = message(threadId: "a:t2")
        draft.labelIds = "DRAFT"
        XCTAssertEqual(
            ComposePlacement.preferred(
                replyTo: nil, editDraft: draft, forward: false,
                selectedThreadId: "a:t2", readingPaneHidden: false),
            .inline)
    }

    func testOffThreadReplyIsFloating() {
        let msg = message(threadId: "a:other")
        XCTAssertEqual(
            ComposePlacement.preferred(
                replyTo: msg, forward: false,
                selectedThreadId: "a:t1", readingPaneHidden: false),
            .floating)
    }

    func testShowsInlineRequiresMatchingThread() {
        let msg = message()
        XCTAssertTrue(ComposePlacement.showsInline(
            inThread: msg.threadId, presentation: .inline,
            replyTo: msg, editDraft: nil))
        XCTAssertFalse(ComposePlacement.showsInline(
            inThread: "a:other", presentation: .inline,
            replyTo: msg, editDraft: nil))
        XCTAssertFalse(ComposePlacement.showsInline(
            inThread: msg.threadId, presentation: .floating,
            replyTo: msg, editDraft: nil))
    }
}
