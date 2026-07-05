import XCTest

final class UpdateCheckerTests: XCTestCase {
    func testNewerVersionsDetected() {
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.1.1", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0", than: "0.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.0"))   // numeric, not lexicographic
    }

    func testEqualOrOlderVersionsNotDetected() {
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1", than: "0.1.0"))     // padded with zeros
    }

    func testJunkComponentsDoNotCrash() {
        XCTAssertFalse(UpdateChecker.isNewer("abc", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.1.1", than: "abc"))
    }
}
