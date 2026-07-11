import XCTest

final class GmailWebLinksTests: XCTestCase {

    func testAuthUserEncodesPlusSign() {
        let encoded = GmailWebLinks.encodeAuthUser("ron+news@example.com")
        XCTAssertFalse(encoded.contains("+"),
                       "bare + would decode as space in query strings")
        XCTAssertTrue(encoded.contains("%2B") || encoded.contains("%2b"))
        XCTAssertTrue(encoded.contains("@"))
    }

    func testThreadURLCarriesAuthUserAndThreadId() {
        let url = GmailWebLinks.threadURL(
            accountEmail: "ada@analytical.engine",
            gmailThreadId: "18abc")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "mail.google.com")
        let s = url?.absoluteString ?? ""
        XCTAssertTrue(s.contains("authuser=ada@analytical.engine")
                      || s.contains("authuser=ada%40analytical.engine"))
        XCTAssertTrue(s.contains("#all/18abc"))
    }

    func testFiltersSettingsURLUsesAuthUserNotUZero() {
        let url = GmailWebLinks.filtersSettingsURL(
            accountEmail: "second@example.com")
        let s = url?.absoluteString ?? ""
        XCTAssertTrue(s.contains("authuser="))
        XCTAssertTrue(s.contains("#settings/filters"))
        XCTAssertFalse(s.contains("/u/0/"),
                       "hardcoded /u/0 opens the wrong multi-account mailbox")
    }

    func testPlusAddressInThreadURL() {
        let url = GmailWebLinks.threadURL(
            accountEmail: "ron+lists@example.com",
            gmailThreadId: "t1")
        let s = url?.absoluteString ?? ""
        XCTAssertFalse(s.contains("authuser=ron+lists"),
                       "+ must be percent-encoded in authuser")
        XCTAssertTrue(s.contains("ron%2Blists") || s.contains("ron%2blists"))
    }
}
