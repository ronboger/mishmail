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

    /// Adversarial: a commented-out `<head>` must not receive the CSP injection
    /// (would leave Ask-policy CSP inert → HTTPS images load).
    func testCSPNotInjectedIntoCommentedHead() {
        let html = """
            <!DOCTYPE html>
            <!-- <head><meta charset="utf-8"></head> -->
            <html>
            <head><title>real</title></head>
            <body><p>Hello</p></body>
            </html>
            """
        let csp = HTMLBodyCSP.metaTag(allowRemoteImages: false)
        let out = HTMLBodyDocument.assemble(html: html, cspMeta: csp, styleCSS: "/*m*/")

        // Comment still present and does not contain our CSP.
        XCTAssertTrue(out.contains("<!-- <head>"))
        if let comment = out.range(of: #"<!--[\s\S]*?-->"#, options: .regularExpression) {
            XCTAssertFalse(out[comment].contains("Content-Security-Policy"),
                           "CSP must not land inside an HTML comment")
        } else {
            XCTFail("expected comment preserved")
        }

        // Injection sits immediately after the real open <head>, before title.
        XCTAssertTrue(out.contains("<head>" + csp),
                      "injection should sit immediately after the real <head>")
        XCTAssertTrue(out.contains("<title>real</title>"))
        XCTAssertTrue(out.contains("<p>Hello</p>"))
    }

    func testHeadInsideStyleIsIgnored() {
        let html = """
            <html>
            <style>/* <head> decoy */ .x{}</style>
            <head id="real"></head>
            <body></body>
            </html>
            """
        let out = HTMLBodyDocument.assemble(
            html: html, cspMeta: "<meta id=csp>", styleCSS: "a{}")
        // Style block still has the decoy text, but CSP is not only there.
        XCTAssertTrue(out.contains("<head id=\"real\"><meta id=csp>"),
                      "must inject into the real head, not style text")
        // Decoy comment in style must not be the only place with meta id=csp
        // before real head — ensure real head open is followed by meta.
        if let styleRange = out.range(of: #"<style>[\s\S]*?</style>"#,
                                      options: .regularExpression) {
            XCTAssertFalse(out[styleRange].contains("<meta id=csp>"))
        }
    }

    func testRangeOfOpeningTagSkipsCommentAndFindsReal() {
        let html = "<!-- <head> --><html><head id=h></head></html>"
        let range = HTMLBodyDocument.rangeOfOpeningTag("head", in: html)
        XCTAssertNotNil(range)
        XCTAssertEqual(String(html[range!]), "<head id=h>")
    }

    func testRangeOfOpeningTagNilWhenOnlyCommented() {
        let html = "<!DOCTYPE html><!-- <head></head> --><html><body>x</body></html>"
        XCTAssertNil(HTMLBodyDocument.rangeOfOpeningTag("head", in: html))
        // Falls back to html open for injection.
        let out = HTMLBodyDocument.injectIntoHead(html, injection: "<meta id=csp>")
        XCTAssertTrue(out.contains("<html><head><meta id=csp></head>"))
        XCTAssertFalse(out.contains("<!-- <head></head><meta id=csp>"))
    }

    /// Quoted `>` inside attributes must not truncate the open tag — otherwise
    /// CSP lands inside the attribute value and is parser-inert (Ask bypass).
    func testHeadOpenTagWithDoubleQuotedGreaterThan() {
        let html = #"<html><head data-decoy=">"><title>t</title></head><body>x</body></html>"#
        let range = HTMLBodyDocument.rangeOfOpeningTag("head", in: html)
        XCTAssertEqual(range.map { String(html[$0]) }, #"<head data-decoy=">">"#)

        let csp = HTMLBodyCSP.metaTag(allowRemoteImages: false)
        let out = HTMLBodyDocument.assemble(html: html, cspMeta: csp, styleCSS: "/*m*/")
        // Injection after the full open tag, not inside the attribute.
        XCTAssertTrue(out.contains(#"<head data-decoy=">">"# + csp),
                      "CSP must follow the complete open tag, not sit in the attr")
        // Attribute still only contains the decoy character, not CSP.
        XCTAssertFalse(out.contains(#"data-decoy=">\#(csp.prefix(20))"#))
        XCTAssertTrue(out.contains("Content-Security-Policy"))
    }

    func testHeadOpenTagWithSingleQuotedGreaterThan() {
        let html = #"<html><head data-decoy='>' id=h></head><body/></html>"#
        let range = HTMLBodyDocument.rangeOfOpeningTag("head", in: html)
        XCTAssertEqual(range.map { String(html[$0]) }, #"<head data-decoy='>' id=h>"#)

        let out = HTMLBodyDocument.injectIntoHead(html, injection: "<meta id=csp>")
        XCTAssertTrue(out.contains(#"<head data-decoy='>' id=h><meta id=csp>"#))
    }

    func testHtmlFallbackWithQuotedGreaterThan() {
        // No real head; inject after <html …> that embeds quoted `>`.
        let html = #"<html data-x=">"><body>x</body></html>"#
        let range = HTMLBodyDocument.rangeOfOpeningTag("html", in: html)
        XCTAssertEqual(range.map { String(html[$0]) }, #"<html data-x=">">"#)
        let out = HTMLBodyDocument.injectIntoHead(html, injection: "<meta id=csp>")
        XCTAssertTrue(out.contains(#"<html data-x=">"><head><meta id=csp></head>"#))
    }

    func testIndexAfterOpenTagCloseSkipsQuotedGreaterThan() {
        let s = Array(#"head data="a>b" data2='c>d'>"#)
        // from after implicit `<` — start at 0 for "head …"
        let end = HTMLBodyDocument.indexAfterOpenTagClose(from: 0, in: s)
        XCTAssertEqual(end, s.count)
        XCTAssertEqual(s[end! - 1], ">")
    }
}
