import XCTest

final class HTMLBodyDocumentTests: XCTestCase {
    func testFragmentIsNotCompleteDocument() {
        XCTAssertFalse(HTMLBodyDocument.isCompleteDocument("<p>Hi</p>"))
        XCTAssertFalse(HTMLBodyDocument.isCompleteDocument(Transactional2FAFixture.fragmentHTML))
        XCTAssertFalse(HTMLBodyDocument.isCompleteDocument(""))
        XCTAssertFalse(HTMLBodyDocument.isCompleteDocument("   "))
    }

    func testCompleteDocumentDetection() {
        XCTAssertTrue(HTMLBodyDocument.isCompleteDocument(
            Transactional2FAFixture.completeDocumentHTML))
        XCTAssertTrue(HTMLBodyDocument.isCompleteDocument(
            "<!DOCTYPE html><html><body>x</body></html>"))
        XCTAssertTrue(HTMLBodyDocument.isCompleteDocument(
            "<HTML><HEAD></HEAD><BODY>x</BODY></HTML>"))
        XCTAssertTrue(HTMLBodyDocument.isCompleteDocument(
            "<!-- preamble --><html><body>x</body></html>"))
        // head+body without leading html still treated as complete.
        XCTAssertTrue(HTMLBodyDocument.isCompleteDocument(
            "<head><title>t</title></head><body>x</body>"))
    }

    func testAssembleWrapsFragment() {
        let csp = HTMLBodyCSP.metaTag(allowRemoteImages: false)
        let css = "body { color: red; }"
        let out = HTMLBodyDocument.assemble(
            html: "<p>Hello Ron</p>", cspMeta: csp, styleCSS: css)
        XCTAssertTrue(out.contains("<html><head>"))
        XCTAssertTrue(out.contains(csp))
        XCTAssertTrue(out.contains("<style>\nbody { color: red; }\n</style>"))
        XCTAssertTrue(out.contains("<body><p>Hello Ron</p></body>"))
        // Must not claim a second outer wrap when already assembled.
        XCTAssertEqual(out.components(separatedBy: "<html>").count - 1, 1)
    }

    func testAssembleInjectsIntoCompleteDocumentHead() {
        let csp = HTMLBodyCSP.metaTag(allowRemoteImages: false)
        let css = "/* mish */"
        let out = HTMLBodyDocument.assemble(
            html: Transactional2FAFixture.completeDocumentHTML,
            cspMeta: csp, styleCSS: css)

        // Author stylesheet preserved (not stripped via body extraction).
        XCTAssertTrue(out.contains(".code { font-size: 32px"),
                      "author <style> must survive head injection")
        XCTAssertTrue(out.contains(csp), "CSP meta must be injected")
        XCTAssertTrue(out.contains("/* mish */"), "MishMail CSS must be injected")
        XCTAssertTrue(out.contains("Hello Ron"))
        XCTAssertTrue(out.contains("119585"))
        // Injection lands inside head, before </head>.
        guard let headOpen = out.range(of: "<head", options: .caseInsensitive),
              let headClose = out.range(of: "</head>", options: .caseInsensitive),
              let cspRange = out.range(of: csp)
        else {
            return XCTFail("missing head markers or CSP")
        }
        XCTAssertTrue(cspRange.lowerBound > headOpen.upperBound)
        XCTAssertTrue(cspRange.upperBound < headClose.lowerBound)
    }

    func testAssembleInjectsHeadWhenHtmlHasNoHead() {
        let html = "<html><body><p>x</p></body></html>"
        let out = HTMLBodyDocument.assemble(
            html: html, cspMeta: "<meta id=csp>", styleCSS: "a{}")
        XCTAssertTrue(out.contains("<head><meta id=csp><style>"))
        XCTAssertTrue(out.contains("<p>x</p>"))
    }

    func testFixtureRemoteImagesAreHTTPSOnlySyntheticHosts() {
        // Guard: fixture must not use real emburse hosts or cleartext images.
        let html = Transactional2FAFixture.completeDocumentHTML
            + Transactional2FAFixture.fragmentHTML
        XCTAssertFalse(html.lowercased().contains("emburse.com"))
        XCTAssertFalse(html.contains("http://"))
        XCTAssertTrue(html.contains("https://cdn.example-emburse.test/"))
    }

    func testCSPBlockedImagesDoNotAllowHTTPSInMeta() {
        // Acceptance: Ask mode CSP must not list https: for img-src.
        let blocked = HTMLBodyCSP.metaTag(allowRemoteImages: false)
        XCTAssertFalse(blocked.contains(" https:"))
        let assembled = HTMLBodyDocument.assemble(
            html: Transactional2FAFixture.completeDocumentHTML,
            cspMeta: blocked,
            styleCSS: HTMLBodyDarkMode.injectedCSS(fontScale: 1, collapseQuote: false))
        // The CSP meta itself must still block; author img tags may mention https.
        guard let metaRange = assembled.range(
            of: #"<meta http-equiv="Content-Security-Policy"[^>]+>"#,
            options: .regularExpression)
        else {
            return XCTFail("CSP meta missing from assembled document")
        }
        let meta = String(assembled[metaRange])
        XCTAssertTrue(meta.contains("img-src data: cid:"))
        XCTAssertFalse(meta.contains("img-src data: cid: https:"))
    }
}
