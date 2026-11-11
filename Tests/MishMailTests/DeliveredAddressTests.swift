import XCTest

final class DeliveredAddressTests: XCTestCase {
    private let own: Set<String> = ["ron@gmail.com", "ron@lab.edu"]

    private func resolve(to: String = "", cc: String = "", bcc: String = "",
                         delivered: String?) -> DeliveredAddress.Result {
        DeliveredAddress.resolve(toHeader: to, ccHeader: cc, bccHeader: bcc,
                                 deliveredTo: delivered, ownEmails: own,
                                 accountId: "ron@gmail.com")
    }

    func testToAddressNeedsNoExtraRow() {
        let r = resolve(to: "Ron <RON@lab.edu>", delivered: "ron@gmail.com")
        XCTAssertEqual(r, .init(email: "ron@lab.edu", source: .to))
        XCTAssertFalse(r.needsOwnRow)
    }

    func testCcAddressNeedsNoExtraRow() {
        let r = resolve(to: "a@x.com", cc: "ron@gmail.com", delivered: nil)
        XCTAssertEqual(r.source, .cc)
        XCTAssertFalse(r.needsOwnRow)
    }

    /// Bcc to an alias: To shows only other people. Gmail prepends the
    /// mailbox hop above the alias hop, so the oldest own alias wins.
    func testBccToAliasUsesDeliveredToChain() {
        let r = resolve(to: "undisclosed-recipients:;",
                        delivered: "ron@gmail.com, ron@lab.edu")
        XCTAssertEqual(r, .init(email: "ron@lab.edu", source: .delivered))
        XCTAssertTrue(r.needsOwnRow)
    }

    func testBccToPrimaryUsesDeliveredToChain() {
        let r = resolve(to: "Team <team@x.com>", delivered: "ron@gmail.com")
        XCTAssertEqual(r, .init(email: "ron@gmail.com", source: .delivered))
    }

    /// A forwarding domain that is not a send-as alias still tells the user
    /// where the mail first arrived.
    func testNonOwnOldestHopIsShown() {
        let r = resolve(to: "a@x.com", delivered: "ron@gmail.com, old@school.edu")
        XCTAssertEqual(r, .init(email: "old@school.edu", source: .delivered))
    }

    func testNoChainFallsBackToMailbox() {
        XCTAssertEqual(resolve(to: "a@x.com", delivered: nil),
                       .init(email: "ron@gmail.com", source: .mailbox))
        XCTAssertEqual(resolve(to: "a@x.com", delivered: ""),
                       .init(email: "ron@gmail.com", source: .mailbox))
    }

    func testOwnBccOnSentMail() {
        let r = resolve(to: "a@x.com", bcc: "ron@lab.edu", delivered: nil)
        XCTAssertEqual(r, .init(email: "ron@lab.edu", source: .bcc))
        XCTAssertTrue(r.needsOwnRow)
    }

    private func message(from: String, to: String, delivered: String?) -> Message {
        Message(id: "ron@gmail.com:m1", accountId: "ron@gmail.com", gmailId: "m1",
                threadId: "ron@gmail.com:t1", fromHeader: from, toHeader: to,
                ccHeader: "", subject: "s", date: Date(), snippet: "",
                bodyText: "", bodyHTML: nil, messageIdHeader: "",
                referencesHeader: "", labelIds: "", isUnread: false, hasAttachment: false,
                deliveredTo: delivered)
    }

    func testReplyFromUsesReceivedAlias() {
        let m = message(from: "Boss <boss@x.com>", to: "undisclosed-recipients:;",
                        delivered: "ron@gmail.com, ron@lab.edu")
        XCTAssertEqual(DeliveredAddress.replyFromEmail(for: m, ownEmails: own), "ron@lab.edu")
    }

    func testReplyFromOwnSentMailKeepsSender() {
        let m = message(from: "Ron <ron@lab.edu>", to: "boss@x.com", delivered: nil)
        XCTAssertEqual(DeliveredAddress.replyFromEmail(for: m, ownEmails: own), "ron@lab.edu")
    }

    func testReplyFromIgnoresNonOwnAndMailboxGuess() {
        let forwarded = message(from: "a@x.com", to: "a@x.com",
                                delivered: "ron@gmail.com, old@school.edu")
        XCTAssertNil(DeliveredAddress.replyFromEmail(for: forwarded, ownEmails: own))
        let unknown = message(from: "a@x.com", to: "a@x.com", delivered: nil)
        XCTAssertNil(DeliveredAddress.replyFromEmail(for: unknown, ownEmails: own))
    }

    func testUnsubscribeFromUsesDeliveredAlias() {
        XCTAssertEqual(ListUnsubscribe.fromEmail(
            toHeader: "News <list@news.example>", ccHeader: "", bccHeader: "",
            deliveredTo: "ron@gmail.com, ron@lab.edu",
            ownEmails: own, accountId: "ron@gmail.com"), "ron@lab.edu")
        // A non-own hop can not send; fall back to the primary.
        XCTAssertEqual(ListUnsubscribe.fromEmail(
            toHeader: "News <list@news.example>", ccHeader: "", bccHeader: "",
            deliveredTo: "ron@gmail.com, old@school.edu",
            ownEmails: own, accountId: "ron@gmail.com"), "ron@gmail.com")
    }
}
