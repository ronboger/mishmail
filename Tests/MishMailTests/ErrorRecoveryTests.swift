import XCTest

final class ErrorRecoveryTests: XCTestCase {
    func testReauthorizationPresentationCarriesItsRecoveryAction() {
        let error = ErrorRecovery.reauthorizationRequired(for: "person@example.org")

        XCTAssertEqual(error.recovery, .reauthorize)
        XCTAssertEqual(
            error.message,
            "person@example.org: needs to be reauthorized (Settings → Accounts).")
    }

    func testRetryPresentationDoesNotInferRecoveryFromMessageWording() {
        let message = "person@example.org: needs to be reauthorized someday."
        let error = ErrorRecovery.retry(message)

        XCTAssertEqual(error.message, message)
        XCTAssertEqual(error.recovery, .retrySync)
    }
}
