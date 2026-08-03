import XCTest

final class ExternalLinkRecoveryTests: XCTestCase {

    // MARK: - Passthrough

    func testHTTPSPassThrough() {
        let url = URL(string: "https://cal.com/stevesimitzis")!
        XCTAssertEqual(
            ExternalLinkRecovery.recoveredExternalURL(from: url),
            url)
    }

    func testHTTPPassThrough() {
        let url = URL(string: "http://example.com/path")!
        XCTAssertEqual(
            ExternalLinkRecovery.recoveredExternalURL(from: url),
            url)
    }

    func testMailtoPassThrough() {
        let url = URL(string: "mailto:ada@example.com")!
        XCTAssertEqual(
            ExternalLinkRecovery.recoveredExternalURL(from: url),
            url)
    }

    func testSchemeCaseInsensitivePassThrough() {
        let url = URL(string: "HTTPS://Example.COM/x")!
        XCTAssertEqual(
            ExternalLinkRecovery.recoveredExternalURL(from: url)?.scheme?.lowercased(),
            "https")
    }

    // MARK: - Schemeless recovery

    func testNilSchemeBareHost() {
        // Foundation parses bare "host/path" with scheme == nil.
        let url = URL(string: "cal.com/stevesimitzis")!
        XCTAssertNil(url.scheme)
        XCTAssertEqual(
            ExternalLinkRecovery.recoveredExternalURL(from: url)?.absoluteString,
            "https://cal.com/stevesimitzis")
    }

    func testAboutBlankSlashForm() {
        let url = URL(string: "about:blank/cal.com/stevesimitzis")!
        XCTAssertEqual(url.scheme?.lowercased(), "about")
        XCTAssertEqual(
            ExternalLinkRecovery.recoveredExternalURL(from: url)?.absoluteString,
            "https://cal.com/stevesimitzis")
    }

    func testAboutBlankPercentEncodedPath() {
        let url = URL(string: "about:blank%2Fcal.com%2Fstevesimitzis")!
        XCTAssertEqual(
            ExternalLinkRecovery.recoveredExternalURL(from: url)?.absoluteString,
            "https://cal.com/stevesimitzis")
    }

    func testAboutResolvedRelativeForm() {
        // URL(string:relativeTo: about:blank) → about:cal.com/…
        let base = URL(string: "about:blank")!
        let url = URL(string: "cal.com/stevesimitzis", relativeTo: base)!.absoluteURL
        XCTAssertEqual(url.scheme?.lowercased(), "about")
        XCTAssertEqual(
            ExternalLinkRecovery.recoveredExternalURL(from: url)?.absoluteString,
            "https://cal.com/stevesimitzis")
    }

    func testAboutSlashAbsolutePathForm() {
        let url = URL(string: "about:/cal.com/stevesimitzis")!
        XCTAssertEqual(
            ExternalLinkRecovery.recoveredExternalURL(from: url)?.absoluteString,
            "https://cal.com/stevesimitzis")
    }

    // MARK: - Rejections (security)

    func testRejectsJavascript() {
        XCTAssertNil(
            ExternalLinkRecovery.recoveredExternalURL(
                from: URL(string: "javascript:alert(1)")))
    }

    func testRejectsFile() {
        XCTAssertNil(
            ExternalLinkRecovery.recoveredExternalURL(
                from: URL(string: "file:///etc/passwd")))
    }

    func testRejectsData() {
        XCTAssertNil(
            ExternalLinkRecovery.recoveredExternalURL(
                from: URL(string: "data:text/html,hi")))
    }

    func testRejectsAboutBlankAlone() {
        XCTAssertNil(
            ExternalLinkRecovery.recoveredExternalURL(
                from: URL(string: "about:blank")))
    }

    func testRejectsNilURL() {
        XCTAssertNil(ExternalLinkRecovery.recoveredExternalURL(from: nil))
    }

    func testRejectsSingleLabel() {
        // "foo" is not a domain; must not open as https://foo
        let url = URL(string: "foo")!
        XCTAssertNil(ExternalLinkRecovery.recoveredExternalURL(from: url))
    }

    func testRejectsFileLookingToken() {
        // Same prior art as TextDirection bare-host isolation: .md is not a TLD.
        let url = URL(string: "readme.md")!
        XCTAssertNil(ExternalLinkRecovery.recoveredExternalURL(from: url))
        let about = URL(string: "about:blank/readme.md")!
        XCTAssertNil(ExternalLinkRecovery.recoveredExternalURL(from: about))
    }

    func testRejectsUnknownTLD() {
        // isLinkableHost refuses non-allowlisted TLDs (e.g. .bar, .sh).
        XCTAssertNil(
            ExternalLinkRecovery.recoveredExternalURL(
                from: URL(string: "foo.bar")))
        XCTAssertNil(
            ExternalLinkRecovery.recoveredExternalURL(
                from: URL(string: "setup.sh")))
    }

    func testRejectsAboutEmbeddedJavascript() {
        XCTAssertNil(
            ExternalLinkRecovery.recoveredExternalURL(
                from: URL(string: "about:javascript:alert(1)")))
    }

    func testRejectsCustomAppScheme() {
        XCTAssertNil(
            ExternalLinkRecovery.recoveredExternalURL(
                from: URL(string: "mishmail://thread/1")))
    }
}
