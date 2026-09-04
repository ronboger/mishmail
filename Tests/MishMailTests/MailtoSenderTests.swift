import XCTest

final class MailtoSenderTests: XCTestCase {

    private func candidate(_ accountId: String, from: String = "", to: String = "",
                           cc: String = "", labels: String = "INBOX")
    -> MailtoSender.Candidate {
        .init(accountId: accountId, fromHeader: from, toHeader: to,
              ccHeader: cc, labelIds: labels)
    }

    // MARK: - lookupAddresses

    func testLookupAddressesNormalizesAndDropsOwn() {
        let out = MailtoSender.lookupAddresses(
            ["Abraham Heifets <Abe@Example.com>", "abe@example.com",
             "me@mine.com", "not-an-email"],
            own: ["Me@Mine.com"])
        XCTAssertEqual(out, ["abe@example.com"])
    }

    func testLookupAddressesKeepsOrder() {
        let out = MailtoSender.lookupAddresses(["b@y.com", "a@x.com"], own: [])
        XCTAssertEqual(out, ["b@y.com", "a@x.com"])
    }

    func testLikeEscapedQuotesMetacharacters() {
        XCTAssertEqual(MailtoSender.likeEscaped("a_b%c\\d@x.com"), "a\\_b\\%c\\\\d@x.com")
        XCTAssertEqual(MailtoSender.likeEscaped("plain@x.com"), "plain@x.com")
    }

    // MARK: - mailbox(matching:in:)

    func testPicksNewestCandidateThatMatches() {
        let out = MailtoSender.mailbox(
            matching: ["abe@example.com"],
            in: [candidate("work@x.com", to: "Abe <abe@example.com>"),
                 candidate("personal@y.com", from: "abe@example.com")])
        XCTAssertEqual(out, "work@x.com")
    }

    func testMatchesOnFromAndCcHeaders() {
        XCTAssertEqual(
            MailtoSender.mailbox(matching: ["abe@example.com"],
                                 in: [candidate("a@x.com", from: "Abe <abe@example.com>")]),
            "a@x.com")
        XCTAssertEqual(
            MailtoSender.mailbox(matching: ["abe@example.com"],
                                 in: [candidate("a@x.com", cc: "abe@example.com")]),
            "a@x.com")
    }

    /// The SQL prefilter is a substring LIKE, so a longer address containing
    /// the target comes back as a candidate. It must not count as a match.
    func testRejectsSubstringOnlyAddressMatch() {
        let out = MailtoSender.mailbox(
            matching: ["abe@example.com"],
            in: [candidate("wrong@x.com", to: "gabe@example.com"),
                 candidate("right@y.com", to: "abe@example.com")])
        XCTAssertEqual(out, "right@y.com")
    }

    func testSkipsSpamAndTrash() {
        let out = MailtoSender.mailbox(
            matching: ["abe@example.com"],
            in: [candidate("spam@x.com", from: "abe@example.com", labels: "SPAM"),
                 candidate("trash@x.com", from: "abe@example.com", labels: "TRASH INBOX"),
                 candidate("real@y.com", from: "abe@example.com")])
        XCTAssertEqual(out, "real@y.com")
    }

    func testMatchIsCaseInsensitive() {
        let out = MailtoSender.mailbox(
            matching: ["abe@example.com"],
            in: [candidate("a@x.com", to: "Abraham <ABE@Example.COM>")])
        XCTAssertEqual(out, "a@x.com")
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(MailtoSender.mailbox(
            matching: ["abe@example.com"],
            in: [candidate("a@x.com", to: "someone@else.com")]))
        XCTAssertNil(MailtoSender.mailbox(matching: [], in: []))
    }
}
