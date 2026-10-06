import XCTest

final class ReplyRecipientsTests: XCTestCase {

    private let me: Set<String> = ["ron@x.com", "alias@x.com"]

    private func compute(from: String, replyTo: String? = nil,
                         to: String = "ron@x.com", cc: String = "",
                         replyAll: Bool = false) -> ReplyRecipients.Result {
        ReplyRecipients.compute(from: from, replyTo: replyTo, to: to, cc: cc,
                                ownAddresses: me, replyAll: replyAll)
    }

    // MARK: - Reply

    func testReplyWithoutReplyToTargetsSender() {
        for replyTo in [nil, "", "   "] as [String?] {
            let r = compute(from: "Jane <jane@ex.com>", replyTo: replyTo)
            XCTAssertEqual(r.to, ["jane@ex.com"])
            XCTAssertEqual(r.cc, [])
        }
    }

    func testReplyUsesReplyToWhenPresent() {
        let r = compute(from: "GitHub <notifications@github.com>",
                        replyTo: "reply+TOKEN@reply.github.com")
        XCTAssertEqual(r.to, ["reply+TOKEN@reply.github.com"])
        XCTAssertEqual(r.cc, [])
    }

    func testReplyToWithDisplayNameAndSeveralAddresses() {
        let r = compute(from: "Acme Forms <noreply@forms.example>",
                        replyTo: "\"Client, The\" <customer@client.example>, Sales <sales@client.example>")
        XCTAssertEqual(r.to, ["customer@client.example", "sales@client.example"])
    }

    func testReplyToEqualToFromIsOneRecipient() {
        let r = compute(from: "Jane <jane@ex.com>", replyTo: "JANE@ex.com, jane@ex.com")
        XCTAssertEqual(r.to, ["JANE@ex.com"])
    }

    func testReplyToWithoutAnAddressFallsBackToSender() {
        let r = compute(from: "Jane <jane@ex.com>", replyTo: "undisclosed-recipients:;")
        XCTAssertEqual(r.to, ["jane@ex.com"])
    }

    func testReplyToOwnMessageIgnoresReplyTo() {
        // My own sent mail can carry a Reply-To (send-as setting). A reply
        // in that thread continues to the people I wrote to.
        let r = compute(from: "Ron <ron@x.com>", replyTo: "replies@x.com",
                        to: "Jane <jane@ex.com>, alias@x.com")
        XCTAssertEqual(r.to, ["jane@ex.com"])
    }

    func testReplyToOwnNoteToSelfTargetsSelf() {
        let r = compute(from: "Ron <RON@x.com>", to: "ron@x.com")
        XCTAssertEqual(r.to, ["RON@x.com"])
    }

    func testReplyDoesNotFillCc() {
        let r = compute(from: "Jane <jane@ex.com>", to: "ron@x.com, bob@ex.com",
                        cc: "carol@ex.com")
        XCTAssertEqual(r.cc, [])
    }

    // MARK: - Reply all

    func testReplyAllWithoutReplyTo() {
        let r = compute(from: "Jane <jane@ex.com>",
                        to: "ron@x.com, Bob <bob@ex.com>, jane@ex.com",
                        cc: "Carol <carol@ex.com>, BOB@ex.com, alias@x.com",
                        replyAll: true)
        XCTAssertEqual(r.to, ["jane@ex.com"])
        XCTAssertEqual(r.cc, ["bob@ex.com", "carol@ex.com"])
    }

    func testReplyAllWithReplyToPutsReplyToInToAndRestInCc() {
        // List mail: Reply-To is the list, which is also in To.
        let r = compute(from: "Jane <jane@ex.com>",
                        replyTo: "Team <team@lists.example>",
                        to: "team@lists.example, ron@x.com",
                        cc: "Bob <bob@ex.com>",
                        replyAll: true)
        XCTAssertEqual(r.to, ["team@lists.example"])
        XCTAssertEqual(r.cc, ["bob@ex.com"])
    }

    func testReplyAllOnOwnMessage() {
        let r = compute(from: "Ron <ron@x.com>", replyTo: "replies@x.com",
                        to: "Jane <jane@ex.com>", cc: "Bob <bob@ex.com>, ron@x.com",
                        replyAll: true)
        XCTAssertEqual(r.to, ["jane@ex.com"])
        XCTAssertEqual(r.cc, ["bob@ex.com"])
    }

    func testOwnAddressMatchIsCaseInsensitive() {
        let r = ReplyRecipients.compute(
            from: "Jane <jane@ex.com>", replyTo: nil,
            to: "Ron@X.com, bob@ex.com", cc: "",
            ownAddresses: ["RON@x.com"], replyAll: true)
        XCTAssertEqual(r.cc, ["bob@ex.com"])
    }

    // MARK: - Message wrapper and the Reply All button

    private func message(from: String, replyTo: String?, to: String, cc: String) -> Message {
        var m = Message(
            id: "ron@x.com:m1", accountId: "ron@x.com", gmailId: "m1",
            threadId: "ron@x.com:t1", fromHeader: from, toHeader: to,
            ccHeader: cc, bccHeader: "", subject: "s",
            date: Date(timeIntervalSince1970: 0), snippet: "", bodyText: "", bodyHTML: nil,
            messageIdHeader: "<m1@mail>", referencesHeader: "",
            labelIds: "INBOX", isUnread: false, hasAttachment: false)
        m.replyToHeader = replyTo
        return m
    }

    func testMessageWrapperReadsReplyToHeader() {
        let m = message(from: "noreply@forms.example", replyTo: "customer@client.example",
                        to: "ron@x.com", cc: "")
        XCTAssertEqual(
            ReplyRecipients.compute(for: m, ownAddresses: me, replyAll: false).to,
            ["customer@client.example"])
    }

    func testReplyAllButtonFollowsReplyTo() {
        // Reply-To is the only other To recipient: Reply All adds nobody.
        let list = message(from: "Jane <jane@ex.com>", replyTo: "team@lists.example",
                           to: "team@lists.example, ron@x.com", cc: "")
        XCTAssertFalse(ReplyComposer.hasAdditionalReplyAllRecipients(list, ownAddresses: me))

        let withCc = message(from: "Jane <jane@ex.com>", replyTo: "team@lists.example",
                             to: "ron@x.com", cc: "bob@ex.com")
        XCTAssertTrue(ReplyComposer.hasAdditionalReplyAllRecipients(withCc, ownAddresses: me))
    }
}
