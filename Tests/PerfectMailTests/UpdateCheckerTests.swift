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

    func testFindAppPrefersPerfectMailName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-update-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("Other.app", isDirectory: true)
        let pm = root.appendingPathComponent("nested/PerfectMail.app", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pm, withIntermediateDirectories: true)
        // Drop a marker so the directories look real to the enumerator.
        try Data().write(to: other.appendingPathComponent("Contents"))
        try Data().write(to: pm.appendingPathComponent("Contents"))

        let found = UpdateChecker.findApp(in: root)
        XCTAssertEqual(found?.lastPathComponent, "PerfectMail.app")
    }

    func testVerifyRejectsPlainDirectory() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-unsigned-\(UUID().uuidString).app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertThrowsError(try UpdateChecker.verifyCodeSignature(of: dir))
    }
}
