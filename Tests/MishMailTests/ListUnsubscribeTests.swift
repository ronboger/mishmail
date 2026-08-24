import XCTest

final class ListUnsubscribeTests: XCTestCase {

    // MARK: - URI extraction

    func testExtractsBracketedMailtoAndHTTPS() {
        let uris = ListUnsubscribe.extractURIs(
            "<mailto:unsub@news.example?subject=unsubscribe>, <https://news.example/u/abc>")
        XCTAssertEqual(uris.map(\.absoluteString), [
            "mailto:unsub@news.example?subject=unsubscribe",
            "https://news.example/u/abc",
        ])
    }

    func testExtractsUnbracketedCommaSeparated() {
        let uris = ListUnsubscribe.extractURIs(
            "mailto:unsub@news.example, https://news.example/leave")
        XCTAssertEqual(uris.count, 2)
        XCTAssertEqual(uris[0].scheme, "mailto")
        XCTAssertEqual(uris[1].host, "news.example")
    }

    func testIgnoresEmptyHeader() {
        XCTAssertTrue(ListUnsubscribe.extractURIs("").isEmpty)
        XCTAssertTrue(ListUnsubscribe.extractURIs("   ").isEmpty)
    }

    func testBracketedWinsOverTrailingJunk() {
        let uris = ListUnsubscribe.extractURIs(
            "<https://news.example/u>, please ignore mailto:not-this@x.com")
        XCTAssertEqual(uris.map(\.absoluteString), ["https://news.example/u"])
    }

    // MARK: - Action preference

    func testOneClickWinsWhenPostHeaderPresent() {
        let offer = ListUnsubscribe.parse(
            listUnsubscribe: "<mailto:unsub@news.example>, <https://news.example/u/abc>",
            listUnsubscribePost: "List-Unsubscribe=One-Click")
        XCTAssertTrue(offer.allowsOneClick)
        XCTAssertEqual(
            offer.preferredAction,
            .oneClick(URL(string: "https://news.example/u/abc")!))
    }

    func testOneClickPostHeaderIgnoresWhitespaceAndCase() {
        XCTAssertTrue(ListUnsubscribe.isOneClickPostHeader(
            "  List-Unsubscribe = One-Click  "))
        XCTAssertTrue(ListUnsubscribe.isOneClickPostHeader(
            "list-unsubscribe=one-click"))
        XCTAssertFalse(ListUnsubscribe.isOneClickPostHeader("One-Click"))
        XCTAssertFalse(ListUnsubscribe.isOneClickPostHeader(""))
    }

    func testMailtoWhenNoOneClick() {
        let offer = ListUnsubscribe.parse(
            listUnsubscribe: "<mailto:leave-list@host.com?subject=unsubscribe>, <https://host.com/unsub>",
            listUnsubscribePost: "")
        guard case .mailto(let mailto) = offer.preferredAction else {
            return XCTFail("expected mailto, got \(String(describing: offer.preferredAction))")
        }
        XCTAssertEqual(mailto.address, "leave-list@host.com")
        XCTAssertEqual(mailto.subject, "unsubscribe")
    }

    func testHTTPSOpenWhenNoMailtoAndNoOneClick() {
        let offer = ListUnsubscribe.parse(
            listUnsubscribe: "<https://host.com/unsub>",
            listUnsubscribePost: "")
        XCTAssertEqual(
            offer.preferredAction,
            .open(URL(string: "https://host.com/unsub")!))
    }

    func testHTTPOpenIsLastResort() {
        let offer = ListUnsubscribe.parse(
            listUnsubscribe: "<http://host.com/unsub>",
            listUnsubscribePost: "")
        XCTAssertEqual(
            offer.preferredAction,
            .open(URL(string: "http://host.com/unsub")!))
    }

    func testOneClickDoesNotPOSTToHTTP() {
        let offer = ListUnsubscribe.parse(
            listUnsubscribe: "<http://host.com/unsub>, <mailto:unsub@host.com>",
            listUnsubscribePost: "List-Unsubscribe=One-Click")
        guard case .mailto(let mailto) = offer.preferredAction else {
            return XCTFail("HTTP must not be one-clicked; got \(String(describing: offer.preferredAction))")
        }
        XCTAssertEqual(mailto.address, "unsub@host.com")
    }

    func testNoActionForGarbage() {
        let offer = ListUnsubscribe.parse(
            listUnsubscribe: "not a url",
            listUnsubscribePost: "")
        XCTAssertNil(offer.preferredAction)
    }

    // MARK: - mailto parse

    func testMailtoQuerySubjectAndBody() {
        let parsed = ListUnsubscribe.parseMailto(
            "mailto:unsub@host.com?subject=please%20unsub&body=remove%20me")
        XCTAssertEqual(parsed?.address, "unsub@host.com")
        XCTAssertEqual(parsed?.subject, "please unsub")
        XCTAssertEqual(parsed?.body, "remove me")
    }

    func testMailtoRejectsMissingAtAndNewlines() {
        XCTAssertNil(ListUnsubscribe.parseMailto("mailto:not-an-email"))
        XCTAssertNil(ListUnsubscribe.parseMailto("mailto:evil%0ABcc:victim@x.com@host.com"))
        XCTAssertNil(ListUnsubscribe.parseMailto("https://host.com/u"))
        XCTAssertNil(ListUnsubscribe.parseMailto(""))
    }

    func testMailtoTakesFirstAddressOnly() {
        let parsed = ListUnsubscribe.parseMailto("mailto:one@host.com,two@host.com")
        XCTAssertEqual(parsed?.address, "one@host.com")
    }

    // MARK: - URL safety

    func testRejectsLoopbackCredentialsAndNonHTTPSForOneClick() {
        XCTAssertFalse(ListUnsubscribe.isSafeOneClickURL(
            URL(string: "http://news.example/u")!))
        XCTAssertFalse(ListUnsubscribe.isSafeOneClickURL(
            URL(string: "https://localhost/u")!))
        XCTAssertFalse(ListUnsubscribe.isSafeOneClickURL(
            URL(string: "https://127.0.0.1/u")!))
        XCTAssertFalse(ListUnsubscribe.isSafeOneClickURL(
            URL(string: "https://10.0.0.5/u")!))
        XCTAssertFalse(ListUnsubscribe.isSafeOneClickURL(
            URL(string: "https://192.168.1.1/u")!))
        XCTAssertFalse(ListUnsubscribe.isSafeOneClickURL(
            URL(string: "https://172.16.0.1/u")!))
        XCTAssertFalse(ListUnsubscribe.isSafeOneClickURL(
            URL(string: "https://[::1]/u")!))
        XCTAssertFalse(ListUnsubscribe.isSafeOneClickURL(
            URL(string: "https://user:pass@news.example/u")!))
        XCTAssertFalse(ListUnsubscribe.isSafeOneClickURL(
            URL(string: "javascript:alert(1)")!))
        XCTAssertTrue(ListUnsubscribe.isSafeOneClickURL(
            URL(string: "https://news.example/u/abc")!))
        XCTAssertTrue(ListUnsubscribe.isSafeBrowserURL(
            URL(string: "http://news.example/u")!))
        XCTAssertTrue(ListUnsubscribe.isSafeOneClickURL(
            URL(string: "https://172.32.0.1/u")!))  // not RFC 1918
    }

    func testUnbracketedMailtoSubjectCommaDoesNotSplit() {
        let uris = ListUnsubscribe.extractURIs(
            "mailto:unsub@news.example?subject=foo,%20bar, https://news.example/leave")
        XCTAssertEqual(uris.count, 2)
        XCTAssertEqual(uris[0].scheme, "mailto")
        XCTAssertTrue(uris[0].absoluteString.contains("foo"))
        XCTAssertEqual(uris[1].host, "news.example")
    }

    func testMailtoDefaultsSubjectToUnsubscribe() {
        let parsed = ListUnsubscribe.parseMailto("mailto:unsub@host.com")
        XCTAssertEqual(parsed?.subject, "unsubscribe")
    }

    func testFromEmailPrefersDeliveredToAlias() {
        let from = ListUnsubscribe.fromEmail(
            toHeader: "Alias <alias@x.com>, Other <other@y.com>",
            ccHeader: "Primary <primary@x.com>",
            bccHeader: "",
            ownEmails: ["primary@x.com", "alias@x.com"],
            accountId: "primary@x.com")
        XCTAssertEqual(from, "alias@x.com")
        let fallback = ListUnsubscribe.fromEmail(
            toHeader: "News <list@news.example>",
            ccHeader: "",
            bccHeader: "",
            ownEmails: ["primary@x.com"],
            accountId: "primary@x.com")
        XCTAssertEqual(fallback, "primary@x.com")
    }

    // MARK: - One-click request

    func testOneClickRequestShape() throws {
        let url = URL(string: "https://news.example/u/abc")!
        let req = try XCTUnwrap(ListUnsubscribe.oneClickRequest(url: url))
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url, url)
        XCTAssertEqual(
            req.value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded")
        XCTAssertEqual(
            String(data: try XCTUnwrap(req.httpBody), encoding: .utf8),
            "List-Unsubscribe=One-Click")
    }

    func testOneClickRequestNilForUnsafeURL() {
        XCTAssertNil(ListUnsubscribe.oneClickRequest(
            url: URL(string: "http://news.example/u")!))
        XCTAssertNil(ListUnsubscribe.oneClickRequest(
            url: URL(string: "https://127.0.0.1/u")!))
    }

    // MARK: - Message helpers

    func testOfferFromMessageNilWhenHeadersUnknown() {
        var msg = sampleMessage()
        msg.listUnsubscribe = nil
        XCTAssertNil(ListUnsubscribe.offer(from: msg))
    }

    func testOfferFromMessageNilWhenHeaderEmpty() {
        var msg = sampleMessage()
        msg.listUnsubscribe = ""
        msg.listUnsubscribePost = ""
        XCTAssertNil(ListUnsubscribe.offer(from: msg))
    }

    func testPreferredMessagePicksNewestWithAction() {
        var older = sampleMessage()
        older.id = "a:m1"
        older.date = Date(timeIntervalSince1970: 1)
        older.listUnsubscribe = "<https://old.example/u>"
        var newer = sampleMessage()
        newer.id = "a:m2"
        newer.date = Date(timeIntervalSince1970: 2)
        newer.listUnsubscribe = "<mailto:unsub@news.example>"
        var none = sampleMessage()
        none.id = "a:m3"
        none.date = Date(timeIntervalSince1970: 3)
        none.listUnsubscribe = ""
        let picked = ListUnsubscribe.preferredMessage(in: [older, none, newer])
        XCTAssertEqual(picked?.id, "a:m2")
    }

    func testConfirmationCopy() {
        XCTAssertEqual(
            ListUnsubscribe.confirmationTitle(fromHeader: "News Weekly <n@x.com>"),
            "Unsubscribe from emails from News Weekly?")
        XCTAssertTrue(
            ListUnsubscribe.confirmationDetail(for: .oneClick(URL(string: "https://x.com/u")!))
                .contains("mailing list"))
        XCTAssertTrue(
            ListUnsubscribe.confirmationDetail(
                for: .mailto(.init(address: "unsub@x.com", subject: "", body: "")))
                .contains("unsub@x.com"))
    }

    private func sampleMessage() -> Message {
        Message(
            id: "a:m1", accountId: "a", gmailId: "m1", threadId: "a:t1",
            fromHeader: "News <news@example.com>", toHeader: "a",
            ccHeader: "", subject: "weekly", date: Date(), snippet: "",
            bodyText: "", bodyHTML: nil, messageIdHeader: "",
            referencesHeader: "", labelIds: "INBOX", isUnread: false,
            hasAttachment: false)
    }
}
