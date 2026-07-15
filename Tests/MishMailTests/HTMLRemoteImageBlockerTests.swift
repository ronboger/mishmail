import Foundation
import XCTest

final class HTMLRemoteImageBlockerTests: XCTestCase {
    func testRulesAreValidJSONAndBlockOnlyHTTPSImages() throws {
        let data = Data(HTMLRemoteImageBlocker.encodedRules.utf8)
        let rules = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(rules.count, 1)
        let trigger = try XCTUnwrap(rules[0]["trigger"] as? [String: Any])
        XCTAssertEqual(trigger["url-filter"] as? String, "^https://")
        XCTAssertEqual(trigger["resource-type"] as? [String], ["image"])
        let action = try XCTUnwrap(rules[0]["action"] as? [String: Any])
        XCTAssertEqual(action["type"] as? String, "block")
    }

    func testTrustedFallbackPlacesCSPBeforeUntrustedMarkup() {
        let hostile = "<html><iframe><head></iframe><body>x</body></html>"
        let csp = HTMLBodyCSP.metaTag(allowRemoteImages: false)
        let output = HTMLBodyDocument.trustedWrapper(
            html: hostile, cspMeta: csp, styleCSS: "body{}")
        let cspIndex = output.range(of: csp)!.lowerBound
        let hostileIndex = output.range(of: hostile)!.lowerBound
        XCTAssertLessThan(cspIndex, hostileIndex)
        XCTAssertTrue(output.hasPrefix("<html><head>"))
    }
}
