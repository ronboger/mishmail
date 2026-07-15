import XCTest

final class DefaultMailClientTests: XCTestCase {

    func testRejectsNonMailto() {
        XCTAssertNil(DefaultMailClient.parseMailto("https://example.com"))
        XCTAssertNil(DefaultMailClient.parseMailto("http://a@b.com"))
        XCTAssertNil(DefaultMailClient.parseMailto(""))
    }

    func testBareAddress() {
        let m = DefaultMailClient.parseMailto("mailto:ada@analytical.engine")
        XCTAssertEqual(m?.to, ["ada@analytical.engine"])
        XCTAssertEqual(m?.cc, [])
        XCTAssertEqual(m?.bcc, [])
        XCTAssertNil(m?.subject)
        XCTAssertNil(m?.body)
    }

    func testSchemeIsCaseInsensitive() {
        let m = DefaultMailClient.parseMailto("MAILTO:Ada@Example.COM")
        XCTAssertEqual(m?.to, ["Ada@Example.COM"])
    }

    func testMultipleToAndQueryHeaders() {
        let raw = "mailto:a@x.com,b@y.com?cc=c@z.com&bcc=d@z.com&subject=Hi%20there&body=Line1%0ALine2"
        let m = DefaultMailClient.parseMailto(raw)
        XCTAssertEqual(m?.to, ["a@x.com", "b@y.com"])
        XCTAssertEqual(m?.cc, ["c@z.com"])
        XCTAssertEqual(m?.bcc, ["d@z.com"])
        XCTAssertEqual(m?.subject, "Hi there")
        XCTAssertEqual(m?.body, "Line1\nLine2")
    }

    func testQueryToAppends() {
        let m = DefaultMailClient.parseMailto("mailto:a@x.com?to=b@y.com")
        XCTAssertEqual(m?.to, ["a@x.com", "b@y.com"])
    }

    func testEmptyMailtoStillParses() {
        // Browser "compose blank" links are valid mailto: with no path.
        let m = DefaultMailClient.parseMailto("mailto:")
        XCTAssertNotNil(m)
        XCTAssertEqual(m?.to, [])
        XCTAssertNil(m?.subject)
    }

    func testSubjectOnly() {
        let m = DefaultMailClient.parseMailto("mailto:?subject=Hello")
        XCTAssertEqual(m?.to, [])
        XCTAssertEqual(m?.subject, "Hello")
    }

    func testPlusAsSpaceInQueryAndEncodedPlusInAddress() {
        // Form encoding: unencoded + → space in query values.
        let m = DefaultMailClient.parseMailto("mailto:user%2Blist@example.com?subject=Hello+World")
        XCTAssertEqual(m?.to, ["user+list@example.com"])
        XCTAssertEqual(m?.subject, "Hello World")
    }

    func testAngleBracketDisplayName() {
        let m = DefaultMailClient.parseMailto("mailto:Ada%20Lovelace%20%3Cada@example.com%3E")
        XCTAssertEqual(m?.to, ["ada@example.com"])
    }

    func testDedupesCaseInsensitive() {
        let m = DefaultMailClient.parseMailto("mailto:A@x.com?to=a@x.com,b@y.com")
        XCTAssertEqual(m?.to, ["A@x.com", "b@y.com"])
    }

    func testURLEntryPoint() {
        let url = URL(string: "mailto:ron@example.com?subject=Ping")!
        let m = DefaultMailClient.parseMailto(url)
        XCTAssertEqual(m?.to, ["ron@example.com"])
        XCTAssertEqual(m?.subject, "Ping")
    }

    func testSemicolonSeparatedTo() {
        let m = DefaultMailClient.parseMailto("mailto:a@x.com;b@y.com")
        XCTAssertEqual(m?.to, ["a@x.com", "b@y.com"])
    }
}
