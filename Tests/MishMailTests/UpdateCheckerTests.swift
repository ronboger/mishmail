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

    func testFindAppPrefersMishMailName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-update-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("Other.app", isDirectory: true)
        let pm = root.appendingPathComponent("nested/MishMail.app", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pm, withIntermediateDirectories: true)
        // Drop a marker so the directories look real to the enumerator.
        try Data().write(to: other.appendingPathComponent("Contents"))
        try Data().write(to: pm.appendingPathComponent("Contents"))

        let found = UpdateChecker.findApp(in: root)
        XCTAssertEqual(found?.lastPathComponent, "MishMail.app")
    }

    func testVerifyRejectsPlainDirectory() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-unsigned-\(UUID().uuidString).app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertThrowsError(try UpdateChecker.verifyCodeSignature(of: dir))
    }

    func testParseChecksumGNUAndBare() {
        let gnu = """
        # comment
        e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  MishMail-0.2.0.zip
        deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef  other.zip
        """
        XCTAssertEqual(
            UpdateChecker.parseChecksum(gnu, assetName: "MishMail-0.2.0.zip"),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        // Binary-mode asterisk form
        let star = "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899 *MishMail-0.2.0.zip\n"
        XCTAssertEqual(
            UpdateChecker.parseChecksum(star, assetName: "MishMail-0.2.0.zip"),
            "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"
        )
        let bare = "ccddeeff00112233445566778899aabbccddeeff00112233445566778899aabb\n"
        XCTAssertEqual(
            UpdateChecker.parseChecksum(bare, assetName: "anything.zip"),
            "ccddeeff00112233445566778899aabbccddeeff00112233445566778899aabb"
        )
        XCTAssertNil(UpdateChecker.parseChecksum("not-a-hash  file.zip", assetName: "file.zip"))
    }

    func testPickChecksumAssetPrefersSHA256SUMS() {
        let names = ["MishMail-1.0.0.zip", "SHA256SUMS", "notes.txt"]
        let urls = names.map { URL(string: "https://example.com/\($0)")! }
        let picked = UpdateChecker.pickChecksumAsset(from: names, urls: urls,
                                                     zipName: "MishMail-1.0.0.zip")
        XCTAssertEqual(picked?.lastPathComponent, "SHA256SUMS")
    }

    func testEvaluateTrustRejectsAdHocSourceUpdate() throws {
        guard let app = Self.builtAppIfPresent() else {
            throw XCTSkip("No built app for trust smoke")
        }
        guard UpdateChecker.teamIdentifier(of: app) == nil else {
            throw XCTSkip("Built app has a Team ID; ad-hoc behavior not applicable")
        }
        XCTAssertThrowsError(
            try UpdateChecker.evaluateTrust(updateApp: app, runningApp: app,
                                            officialRelease: true)
        ) { error in
            XCTAssertEqual(error as? UpdateChecker.UpdateError, .notDeveloperID)
        }
    }

    private static func builtAppIfPresent() -> URL? {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for rel in [
            "build/dd.noindex/Build/Products/Debug/MishMail Debug.app",
            "build/dd.noindex/Build/Products/Release/MishMail.app",
        ] {
            let url = repo.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
