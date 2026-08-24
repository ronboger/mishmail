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

    func testMishMailThreadLinkRoundTripsAccountAndToken() {
        let url = MishMailDeepLinks.threadURL(
            accountEmail: "ron+mail@example.com", token: "18Abc_def-1")
        XCTAssertEqual(url?.scheme, "mishmail")
        XCTAssertEqual(url?.host, "thread")
        XCTAssertEqual(
            url.flatMap(MishMailDeepLinks.parseThreadURL),
            .init(token: "18Abc_def-1", accountEmail: "ron+mail@example.com"))
    }

    func testMishMailThreadLinkAllowsUnknownAccount() {
        let url = URL(string: "mishmail://thread/18abc")!
        XCTAssertEqual(
            MishMailDeepLinks.parseThreadURL(url),
            .init(token: "18abc", accountEmail: nil))
    }

    func testMishMailThreadLinkRejectsUnexpectedRoutesAndTokens() {
        XCTAssertNil(MishMailDeepLinks.parseThreadURL(
            URL(string: "mishmail://settings/18abc")!))
        XCTAssertNil(MishMailDeepLinks.parseThreadURL(
            URL(string: "mishmail://thread/a/b")!))
        XCTAssertNil(MishMailDeepLinks.threadURL(
            accountEmail: "not-an-email", token: "18abc"))
        XCTAssertNil(MishMailDeepLinks.threadURL(
            accountEmail: nil, token: "bad token"))
    }

    /// ⌘L copies a gmail.com conversation URL (opens in the browser), not
    /// a `mishmail://` deep link. Plus-addresses must stay encoded so
    /// `authuser` selects the right mailbox.
    func testCopyLinkStringIsGmailWebURL() {
        let s = GmailWebLinks.copyPasteboardString(
            accountEmail: "ron+mail@example.com", gmailThreadId: "18Abc_def-1")
        let url = s.flatMap(URL.init(string:))
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "mail.google.com")
        let text = s ?? ""
        XCTAssertTrue(text.contains("#all/18Abc_def-1"))
        XCTAssertTrue(text.contains("ron%2Bmail") || text.contains("ron%2bmail"))
        XCTAssertFalse(text.contains("mishmail"))
        XCTAssertFalse(text.contains("authuser=ron+mail"),
                       "bare + would decode as space in query strings")
    }

    func testCopyLinkStringRejectsInvalidIds() {
        XCTAssertNil(GmailWebLinks.copyPasteboardString(
            accountEmail: "not-an-email", gmailThreadId: "18abc"))
        XCTAssertNil(GmailWebLinks.copyPasteboardString(
            accountEmail: "a@b.com", gmailThreadId: "bad token"))
        XCTAssertNil(GmailWebLinks.copyPasteboardString(
            accountEmail: "a@b.com", gmailThreadId: ""))
        XCTAssertNil(GmailWebLinks.copyPasteboardString(
            accountEmail: "", gmailThreadId: "18abc"))
    }
}
