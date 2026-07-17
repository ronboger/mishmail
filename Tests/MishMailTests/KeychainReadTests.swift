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

    func testExistingOrCreateCreatesOnlyForConfirmedMissingItem() throws {
        var createCount = 0
        let existing = try Keychain.existingOrCreate(from: .value("saved")) {
            createCount += 1
            return "new"
        }
        XCTAssertEqual(existing, "saved")
        XCTAssertEqual(createCount, 0)

        let created = try Keychain.existingOrCreate(from: .notFound) {
            createCount += 1
            return "new"
        }
        XCTAssertEqual(created, "new")
        XCTAssertEqual(createCount, 1)
    }

    func testExistingOrCreateFailsClosedWhenKeychainUnavailable() {
        var createCount = 0
        XCTAssertThrowsError(try Keychain.existingOrCreate(
            from: .unavailable(errSecInteractionNotAllowed)
        ) {
            createCount += 1
            return "new"
        }) { error in
            XCTAssertEqual(
                error as? KeychainError,
                .status(errSecInteractionNotAllowed))
        }
        XCTAssertEqual(createCount, 0)
    }
}
