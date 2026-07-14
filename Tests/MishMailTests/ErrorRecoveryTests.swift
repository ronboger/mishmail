import XCTest

final class ErrorRecoveryTests: XCTestCase {
    func testCurrentReauthErrorOpensAccountRecovery() {
        XCTAssertEqual(ErrorRecovery.action(
            for: "person@example.org: needs to be reauthorized (Settings → Accounts).",
            accountsNeedingReauth: ["person@example.org"]), .reauthorize)
    }

    func testUnrelatedNetworkErrorKeepsRetryEvenWhenAnotherAccountNeedsReauth() {
        XCTAssertEqual(ErrorRecovery.action(
            for: "other@example.org: The Internet connection appears to be offline.",
            accountsNeedingReauth: ["person@example.org"]), .retrySync)
    }

    func testGenericErrorKeepsRetry() {
        XCTAssertEqual(ErrorRecovery.action(
            for: "Request timed out.", accountsNeedingReauth: []), .retrySync)
    }
}
