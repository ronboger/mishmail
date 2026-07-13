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
