import XCTest

final class MailtoSenderTests: XCTestCase {

    func testLookupAddressesNormalizesAndDropsOwn() {
        let out = MailtoSender.lookupAddresses(
            ["Abraham Heifets <Abe@Example.com>", "abe@example.com", "me@mine.com", "not-an-email"],
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
}
