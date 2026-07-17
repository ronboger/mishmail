import Security
import XCTest

final class KeychainReadTests: XCTestCase {
    func testSuccessfulReadDecodesValue() {
        XCTAssertEqual(
            Keychain.classifyRead(status: errSecSuccess, data: Data("token".utf8)),
            .value("token"))
    }

    func testMissingItemIsDistinctFromUnavailableKeychain() {
        XCTAssertEqual(
            Keychain.classifyRead(status: errSecItemNotFound, data: nil),
            .notFound)
        XCTAssertEqual(
            Keychain.classifyRead(status: errSecInteractionNotAllowed, data: nil),
            .unavailable(errSecInteractionNotAllowed))
    }

    func testUndecodableSuccessfulReadFailsClosed() {
        XCTAssertEqual(
            Keychain.classifyRead(status: errSecSuccess, data: Data([0xFF])),
            .unavailable(errSecDecode))
    }
}
