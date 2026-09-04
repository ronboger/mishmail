import XCTest

final class MailtoSenderTests: XCTestCase {

    /// `daysAgo` orders candidates by recency; storage order is deliberately
    /// unrelated to it, matching the unsorted query the store runs.
    private func candidate(_ accountId: String, from: String = "", to: String = "",
                           cc: String = "", labels: String = "INBOX",
                           daysAgo: Double = 0) -> MailtoSender.Candidate {
        .init(accountId: accountId, fromHeader: from, toHeader: to,
              ccHeader: cc, labelIds: labels,
              date: Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86_400))
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

    func testPicksNewestMatchRegardlessOfRowOrder() {
        let out = MailtoSender.mailbox(
            matching: ["abe@example.com"],
            in: [candidate("personal@y.com", from: "abe@example.com", daysAgo: 30),
                 candidate("work@x.com", to: "Abe <abe@example.com>", daysAgo: 1)])
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
            in: [candidate("wrong@x.com", to: "gabe@example.com", daysAgo: 1),
                 candidate("right@y.com", to: "abe@example.com", daysAgo: 30)])
        XCTAssertEqual(out, "right@y.com")
    }

    func testSkipsSpamAndTrash() {
        let out = MailtoSender.mailbox(
            matching: ["abe@example.com"],
            in: [candidate("spam@x.com", from: "abe@example.com",
                           labels: "SPAM", daysAgo: 1),
                 candidate("trash@x.com", from: "abe@example.com",
                           labels: "TRASH INBOX", daysAgo: 2),
                 candidate("real@y.com", from: "abe@example.com", daysAgo: 30)])
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
