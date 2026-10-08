import XCTest

final class PlainTextLinksTests: XCTestCase {

    private func urls(_ text: String) -> [String] {
        PlainTextLinks.links(in: text).map(\.url.absoluteString)
    }

    private func linkedText(_ text: String) -> [String] {
        let ns = text as NSString
        return PlainTextLinks.links(in: text).map { ns.substring(with: $0.range) }
    }

    func testHTTPAndHTTPSLinks() {
        XCTAssertEqual(urls("Join: https://meet.example.com/abc"),
                       ["https://meet.example.com/abc"])
        XCTAssertEqual(urls("a http://a.com/x b HTTPS://B.com/y?z=1#f c"),
                       ["http://a.com/x", "HTTPS://B.com/y?z=1#f"])
        XCTAssertEqual(urls("no links here, not even example.com"), [])
    }

    func testTrailingPunctuationStaysOutside() {
        XCTAssertEqual(linkedText("see https://a.com/x."), ["https://a.com/x"])
        XCTAssertEqual(linkedText("is it https://a.com/x?! yes"), ["https://a.com/x"])
        XCTAssertEqual(linkedText("\"https://a.com/x\", he said"), ["https://a.com/x"])
        XCTAssertEqual(linkedText("<https://a.com/x>"), ["https://a.com/x"])
        // A query keeps its inner punctuation.
        XCTAssertEqual(linkedText("https://a.com/x?a=1,2;b=3."), ["https://a.com/x?a=1,2;b=3"])
    }

    func testUnbalancedClosingBracketsAreTrimmed() {
        XCTAssertEqual(linkedText("(see https://a.com/x)"), ["https://a.com/x"])
        XCTAssertEqual(linkedText("[https://a.com/x]."), ["https://a.com/x"])
        // Balanced brackets belong to the URL.
        XCTAssertEqual(linkedText("https://en.wikipedia.org/wiki/Swift_(language)"),
                       ["https://en.wikipedia.org/wiki/Swift_(language)"])
        XCTAssertEqual(linkedText("(https://en.wikipedia.org/wiki/Swift_(language))."),
                       ["https://en.wikipedia.org/wiki/Swift_(language)"])
    }

    func testOnlyHTTPAndMailtoSchemes() {
        XCTAssertEqual(urls("javascript:alert(1) file:///etc/passwd data:text/html,x"), [])
        XCTAssertEqual(urls("ftp://a.com/x x-apple.systempreferences:foo tel:+15551234"), [])
        XCTAssertEqual(urls("vbscript:https://a.com"), ["https://a.com"])
        // No host: nothing to open.
        XCTAssertEqual(urls("https:// and http:///x and mailto:"), [])
    }

    func testMailtoAndBareAddresses() {
        XCTAssertEqual(urls("write mailto:a@b.com?subject=Hi now"),
                       ["mailto:a@b.com?subject=Hi"])
        XCTAssertEqual(urls("Contact jane.doe+news@mail.example.co.uk."),
                       ["mailto:jane.doe+news@mail.example.co.uk"])
        XCTAssertEqual(linkedText("Contact <jane@example.com>, thanks"), ["jane@example.com"])
        // Not addresses.
        XCTAssertEqual(urls("@handle, a@b, user@localhost, 5@3.5, x@y.c"), [])
        // An address inside a URL is part of that URL, and scp-style
        // `git@host:path` is not a mailbox.
        XCTAssertEqual(urls("https://a.com/u?email=jo@b.com"), ["https://a.com/u?email=jo@b.com"])
        XCTAssertEqual(urls("git clone git@github.com:org/repo.git"), [])
    }

    func testLinksAreSortedAndDoNotOverlap() {
        let text = "a@b.com then https://a.com then c@d.org"
        let links = PlainTextLinks.links(in: text)
        XCTAssertEqual(links.map(\.url.absoluteString),
                       ["mailto:a@b.com", "https://a.com", "mailto:c@d.org"])
        for (a, b) in zip(links, links.dropFirst()) {
            XCTAssertLessThanOrEqual(a.range.location + a.range.length, b.range.location)
        }
    }

    func testAttributedStringKeepsTextAndCarriesLinks() {
        let text = "Héllo 👋 see https://a.com/x.\nMail jo@b.com\n"
        let attr = PlainTextLinks.attributed(text)
        XCTAssertEqual(String(attr.characters), text)
        let linked = attr.runs.compactMap { run -> (String, String)? in
            guard let url = run.link else { return nil }
            return (String(attr[run.range].characters), url.absoluteString)
        }
        XCTAssertEqual(linked.map(\.0), ["https://a.com/x", "jo@b.com"])
        XCTAssertEqual(linked.map(\.1), ["https://a.com/x", "mailto:jo@b.com"])
        // No link: one plain run, text unchanged.
        let plain = PlainTextLinks.attributed("just text")
        XCTAssertEqual(String(plain.characters), "just text")
        XCTAssertTrue(plain.runs.allSatisfy { $0.link == nil })
        XCTAssertEqual(String(PlainTextLinks.attributed("").characters), "")
    }

    func testScanIsCappedForLargeBodies() {
        let filler = String(repeating: "x ", count: PlainTextLinks.maxScanLength / 2)
        let text = "https://early.example.com " + filler + " https://late.example.com"
        XCTAssertEqual(urls(text), ["https://early.example.com"])
        XCTAssertEqual(String(PlainTextLinks.attributed(text).characters), text)
        // A URL cut by the cap is not linked as a shorter, different URL.
        let pad = String(repeating: "y", count: PlainTextLinks.maxScanLength - 12)
        XCTAssertEqual(urls(pad + " https://cut.example.com/path"), [])
        // Link count is bounded too.
        let many = String(repeating: "https://a.com ", count: PlainTextLinks.maxLinks + 50)
        XCTAssertEqual(PlainTextLinks.links(in: many).count, PlainTextLinks.maxLinks)
    }

    func testExternalURLAllowList() {
        XCTAssertNotNil(PlainTextLinks.externalURL(for: URL(string: "https://a.com")!))
        XCTAssertNotNil(PlainTextLinks.externalURL(for: URL(string: "HTTP://a.com")!))
        XCTAssertNotNil(PlainTextLinks.externalURL(for: URL(string: "mailto:a@b.com")!))
        XCTAssertNil(PlainTextLinks.externalURL(for: URL(string: "file:///etc/passwd")!))
        XCTAssertNil(PlainTextLinks.externalURL(for: URL(string: "javascript:alert(1)")!))
        XCTAssertNil(PlainTextLinks.externalURL(for: URL(string: "mishmail://thread/x")!))
        XCTAssertNil(PlainTextLinks.externalURL(for: URL(string: "a.com/path")!))
    }
}
