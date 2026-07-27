import XCTest

final class CIDImageInlinerTests: XCTestCase {

    func testNormalizeStripsAngleBracketsAndCidPrefix() {
        XCTAssertEqual(CIDImageInliner.normalize("<img001@usps>"), "img001@usps")
        XCTAssertEqual(CIDImageInliner.normalize("cid:img001@usps"), "img001@usps")
        XCTAssertEqual(CIDImageInliner.normalize("CID:<Img001@USPS>"), "img001@usps")
        XCTAssertEqual(CIDImageInliner.normalize("cid:img%40001%40x"), "img@001@x")
    }

    func testReferencedIDsFindsQuotedAndUnquoted() {
        let html = #"""
        <img src="cid:one@x" alt="a">
        <img src='cid:two@x' alt="b">
        <img src=cid:three@x alt="c">
        <img src="https://example.com/x.png">
        """#
        XCTAssertEqual(
            CIDImageInliner.referencedIDs(in: html),
            Set(["one@x", "two@x", "three@x"]))
    }

    func testRewriteReplacesOnlyKnownParts() {
        let png = Data([0x89, 0x50, 0x4E, 0x47]) // not a full PNG; fine for URI
        let parts: [String: (mimeType: String, data: Data)] = [
            "mailpiece1": ("image/png", png)
        ]
        let html = #"<img src="cid:mailpiece1" alt="Mailpiece Image"><img src="cid:missing" alt="x">"#
        let out = CIDImageInliner.rewrite(html, parts: parts)
        XCTAssertTrue(out.contains("data:image/png;base64,"))
        XCTAssertTrue(out.contains("cid:missing"), "unmatched cid must remain")
        XCTAssertFalse(out.contains("cid:mailpiece1"))
        XCTAssertTrue(out.contains("alt=\"Mailpiece Image\""))
    }

    func testRewriteIsNoopWithoutPartsOrCids() {
        let html = #"<img src="https://x.com/a.png">"#
        XCTAssertEqual(CIDImageInliner.rewrite(html, parts: [:]), html)
        XCTAssertEqual(
            CIDImageInliner.rewrite(#"<img src="cid:a">"#, parts: [:]),
            #"<img src="cid:a">"#)
    }

    func testSanitizeMIMERejectsNonImage() {
        XCTAssertEqual(CIDImageInliner.sanitizeMIME("image/png"), "image/png")
        XCTAssertEqual(CIDImageInliner.sanitizeMIME("image/jpeg; charset=binary"),
                       "image/jpeg")
        XCTAssertEqual(CIDImageInliner.sanitizeMIME("text/html"), "image/jpeg")
        // SVG is the one image type with a script grammar — always relabeled.
        XCTAssertEqual(CIDImageInliner.sanitizeMIME("image/svg+xml"), "image/jpeg")
    }

    func testContainsCIDReferences() {
        XCTAssertTrue(CIDImageInliner.containsCIDReferences(#"<img src="cid:x">"#))
        XCTAssertFalse(CIDImageInliner.containsCIDReferences(#"<img src="https://x">"#))
    }
}
