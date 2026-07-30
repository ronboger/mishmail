import XCTest

final class HTMLBodyDocumentTests: XCTestCase {
    private let csp = HTMLBodyCSP.metaTag(allowRemoteImages: false)

    /// The structural invariant the whole pane relies on: the trusted head
    /// (CSP + MishMail CSS) precedes every byte of untrusted markup, so no
    /// decoy inside the message can displace or precede the policy.
    private func assertTrustedHeadPrecedesMarkup(_ html: String,
                                                 file: StaticString = #filePath,
                                                 line: UInt = #line) {
        let css = "/* mish */"
        let out = HTMLBodyDocument.assemble(html: html, cspMeta: csp, styleCSS: css)
        XCTAssertTrue(out.hasPrefix("<html><head>\(csp)"), file: file, line: line)
        let bodyOpen = "<head>\(csp)<style>\n\(css)\n</style></head><body>"
        XCTAssertTrue(out.hasPrefix("<html>" + bodyOpen), file: file, line: line)
        XCTAssertTrue(out.hasSuffix("</body></html>"), file: file, line: line)
        if !html.isEmpty {
            XCTAssertTrue(out.contains(html), "message markup preserved verbatim",
                          file: file, line: line)
        }
    }

    func testAssembleWrapsFragment() {
        let css = "body { color: red; }"
        let out = HTMLBodyDocument.assemble(
            html: "<p>Hello Ron</p>", cspMeta: csp, styleCSS: css)
        XCTAssertTrue(out.contains("<html><head>"))
        XCTAssertTrue(out.contains(csp))
        XCTAssertTrue(out.contains("<style>\nbody { color: red; }\n</style>"))
        XCTAssertTrue(out.contains("<body><p>Hello Ron</p></body></html>"))
        // Must not claim a second outer wrap when already assembled.
        XCTAssertEqual(out.components(separatedBy: "<html>").count - 1, 1)
    }

    func testAssembleWrapsCompleteDocument() {
        assertTrustedHeadPrecedesMarkup(Transactional2FAFixture.completeDocumentHTML)
        let out = HTMLBodyDocument.assemble(
            html: Transactional2FAFixture.completeDocumentHTML,
            cspMeta: csp, styleCSS: "/* mish */")
        // Author stylesheet text preserved (it still applies, now from body).
        XCTAssertTrue(out.contains(".code { font-size: 32px"),
                      "author <style> must survive wrapping")
        XCTAssertTrue(out.contains("Hello Ron"))
        XCTAssertTrue(out.contains("119585"))
    }

    /// Adversarial battery: decoy `<head>` elements inside containers whose
    /// contents the HTML parser treats as inert, raw text, or foreign content
    /// must not attract the CSP — the policy is ahead of all of them by
    /// construction. (These are the documents that defeated head injection.)
    func testDecoyHeadsCannotDisplaceCSP() {
        let decoys = [
            // Template contents are an inert fragment.
            "<html><template><head></head></template><head><title>t</title></head><body>x</body>",
            // Iframe fallback content.
            "<html><iframe><head></head></iframe><head></head><body>x</body></html>",
            // noscript parses as markup when scripting is disabled (it is).
            "<html><noscript><head></head></noscript><head></head><body>x</body></html>",
            // Everything after <plaintext> is literal text.
            "<html><plaintext><head></head>",
            // SVG/MathML foreign-content breakout.
            "<html><svg><head></head></svg><body>x</body></html>",
            // Commented-out head.
            "<!DOCTYPE html><!-- <head></head> --><html><head><title>t</title></head><body>x</body></html>",
            // Head open tag embedding a quoted `>`.
            #"<html><head data-decoy=">"><title>t</title></head><body>x</body></html>"#,
            // Raw-text element holding a head-looking string.
            "<html><style>/* <head> */ .x{}</style><head></head><body>x</body></html>",
        ]
        for html in decoys {
            assertTrustedHeadPrecedesMarkup(html)
        }
    }

    func testAssembleHeadlessAndEmptyDocuments() {
        assertTrustedHeadPrecedesMarkup("<html><body><p>x</p></body></html>")
        assertTrustedHeadPrecedesMarkup("<head><title>t</title></head><body>x</body>")
        assertTrustedHeadPrecedesMarkup("")
        assertTrustedHeadPrecedesMarkup("   ")
    }

    /// An attacker CSP meta inside the message may only ever tighten the
    /// policy: ours is first in document order and applies unconditionally.
    func testAttackerMetaCannotPrecedeTrustedHead() {
        let evil = #"<html><head><meta http-equiv="Content-Security-Policy" content="default-src *"></head><body>x</body></html>"#
        let out = HTMLBodyDocument.assemble(html: evil, cspMeta: csp, styleCSS: "a{}")
        XCTAssertTrue(out.hasPrefix("<html><head>\(csp)"))
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
            styleCSS: HTMLBodyDarkMode.injectedCSS(fontScale: 1))
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
