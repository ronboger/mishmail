import XCTest

/// Pure helpers behind draft cards + reply-parent selection (no DB / MailStore instance).
final class DraftThreadHelpersTests: XCTestCase {

    private func msg(id: String, labels: String, date offset: TimeInterval = 0) -> Message {
        Message(
            id: "a:\(id)", accountId: "a", gmailId: id,
            threadId: "a:t1", fromHeader: "Ron <a@x.com>", toHeader: "b@x.com",
            ccHeader: "", bccHeader: "", subject: "Re: hi",
            date: Date(timeIntervalSince1970: 1_783_372_500 + offset),
            snippet: "", bodyText: "body \(id)", bodyHTML: nil,
            messageIdHeader: "<\(id)@mail>", referencesHeader: "",
            labelIds: labels, isUnread: false, hasAttachment: false)
    }

    func testNewestSentSkipsTrailingDraft() {
        let msgs = [
            msg(id: "1", labels: "INBOX", date: 0),
            msg(id: "2", labels: "INBOX SENT", date: 10),
            msg(id: "3", labels: "DRAFT", date: 20),
        ]
        XCTAssertEqual(ForwardComposer.newestSentMessage(in: msgs)?.gmailId, "2")
    }

    func testNewestSentNilWhenOnlyDrafts() {
        let msgs = [msg(id: "d1", labels: "DRAFT"), msg(id: "d2", labels: "DRAFT")]
        XCTAssertNil(ForwardComposer.newestSentMessage(in: msgs))
    }

    func testNewestSentWhenNoDrafts() {
        let msgs = [msg(id: "1", labels: "INBOX"), msg(id: "2", labels: "SENT")]
        XCTAssertEqual(ForwardComposer.newestSentMessage(in: msgs)?.gmailId, "2")
    }

    func testNewestDraftIsLastDraftNotLastMessage() {
        let msgs = [
            msg(id: "1", labels: "INBOX"),
            msg(id: "d1", labels: "DRAFT", date: 5),
            msg(id: "2", labels: "SENT", date: 10),
            msg(id: "d2", labels: "DRAFT", date: 15),
        ]
        XCTAssertEqual(ForwardComposer.newestDraft(in: msgs)?.gmailId, "d2")
    }

    func testLiveDraftRequiresDraftWithoutTrash() {
        XCTAssertTrue(ForwardComposer.isLiveDraft("DRAFT"))
        XCTAssertTrue(ForwardComposer.isLiveDraft("INBOX DRAFT"))
        XCTAssertFalse(ForwardComposer.isLiveDraft("DRAFT TRASH"))
        XCTAssertFalse(ForwardComposer.isLiveDraft("TRASH DRAFT"))
        XCTAssertFalse(ForwardComposer.isLiveDraft("INBOX"))
        XCTAssertTrue(ForwardComposer.isDiscardedDraft("DRAFT TRASH"))
        XCTAssertFalse(ForwardComposer.isDiscardedDraft("DRAFT"))
    }

    func testNewestDraftSkipsDiscardedDraftTrash() {
        let msgs = [
            msg(id: "1", labels: "INBOX"),
            msg(id: "d1", labels: "DRAFT TRASH", date: 5),
            msg(id: "d2", labels: "DRAFT", date: 10),
            msg(id: "d3", labels: "DRAFT TRASH", date: 15),
        ]
        XCTAssertEqual(ForwardComposer.newestDraft(in: msgs)?.gmailId, "d2")
    }

    func testNewestDraftNilWhenOnlyDiscarded() {
        let msgs = [
            msg(id: "1", labels: "INBOX"),
            msg(id: "d1", labels: "DRAFT TRASH"),
        ]
        XCTAssertNil(ForwardComposer.newestDraft(in: msgs))
    }

    func testRemoteDraftIdMatchesGmailMessageId() {
        let drafts: [(id: String, messageId: String)] = [
            (id: "r-1", messageId: "m1"),
            (id: "r-2", messageId: "m2"),
        ]
        XCTAssertEqual(
            ForwardComposer.remoteDraftId(forGmailMessageId: "m2", drafts: drafts),
            "r-2")
        XCTAssertNil(
            ForwardComposer.remoteDraftId(forGmailMessageId: "gone", drafts: drafts),
            "listDrafts miss must not invent a draft id")
    }

    func testAuthoredPreviewEmptyComposeSaveUsesReplyComposerShape() {
        // Reply opened, user typed nothing, closed → body is "\n\n" + plainQuote.
        let original = msg(id: "orig", labels: "INBOX")
        // Use a real Message shape ReplyComposer expects.
        let full = Message(
            id: original.id, accountId: original.accountId, gmailId: original.gmailId,
            threadId: original.threadId, fromHeader: "Matt <m@x.com>",
            toHeader: "a@x.com", ccHeader: "", bccHeader: "", subject: "hi",
            date: original.date, snippet: "", bodyText: "Let's find time",
            bodyHTML: nil, messageIdHeader: original.messageIdHeader,
            referencesHeader: "", labelIds: "INBOX", isUnread: false, hasAttachment: false)
        let body = "\n\n" + ReplyComposer.plainQuote(of: full)
        XCTAssertEqual(QuotedReply.authoredPreview(text: body, html: nil), "",
                       "empty-authored reply draft must not preview the quote trail")
    }
}
