import XCTest

final class DemoSeedTests: XCTestCase {
    func testDemoCanStartWithoutAccounts() {
        XCTAssertTrue(DemoSeed.canActivate(accountIDs: []))
    }

    func testDemoCanReseedItsOwnFixture() {
        XCTAssertTrue(DemoSeed.canActivate(accountIDs: [DemoSeed.account]))
    }

    func testDemoCannotReplaceARealAccount() {
        XCTAssertFalse(DemoSeed.canActivate(accountIDs: ["person@example.org"]))
        XCTAssertFalse(DemoSeed.canActivate(
            accountIDs: [DemoSeed.account, "person@example.org"]))
    }
}
