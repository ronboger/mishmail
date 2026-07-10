import XCTest

final class HTMLBodyCSPTests: XCTestCase {
    func testBlocksBaseURIAndForms() {
        let csp = HTMLBodyCSP.metaTag(allowRemoteImages: false)
        XCTAssertTrue(csp.contains("default-src 'none'"))
        XCTAssertTrue(csp.contains("base-uri 'none'"))
        XCTAssertTrue(csp.contains("form-action 'none'"))
        XCTAssertTrue(csp.contains("frame-src 'none'"))
        XCTAssertTrue(csp.contains("object-src 'none'"))
        XCTAssertTrue(csp.contains("style-src 'unsafe-inline'"))
    }

    func testRemoteImagesAreHTTPSOnly() {
        let blocked = HTMLBodyCSP.metaTag(allowRemoteImages: false)
        XCTAssertTrue(blocked.contains("img-src data: cid:"))
        XCTAssertFalse(blocked.contains("img-src data: cid: https:"))
        // Scheme tokens only — don't match the meta's `http-equiv` attribute.
        XCTAssertFalse(blocked.contains(" https:"))
        XCTAssertFalse(blocked.contains(" http:"))

        let allowed = HTMLBodyCSP.metaTag(allowRemoteImages: true)
        XCTAssertTrue(allowed.contains("img-src data: cid: https:"))
        // Cleartext image loads stay banned even when remote images are on.
        XCTAssertFalse(allowed.contains(" http:"))
    }
}
