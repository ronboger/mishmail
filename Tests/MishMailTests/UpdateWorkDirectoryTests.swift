import XCTest

/// The update pipeline's scratch directory: it must not outlive the install
/// that created it, and directories orphaned by earlier runs must eventually
/// be swept.
final class UpdateWorkDirectoryTests: XCTestCase {

    private func scratchRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-workdir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @discardableResult
    private func makeDir(_ name: String, in root: URL, created: Date? = nil) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: dir.appendingPathComponent("release.zip").path, contents: Data("zip".utf8)))
        if let created {
            try FileManager.default.setAttributes([.creationDate: created,
                                                   .modificationDate: created],
                                                  ofItemAtPath: dir.path)
        }
        return dir
    }

    // MARK: - Explicit removal

    func testRemoveWorkDirectoryDeletesItAndItsContents() throws {
        let root = try scratchRoot()
        let work = try makeDir("MishMailUpdate-\(UUID().uuidString)", in: root)

        UpdateChecker.removeWorkDirectory(work)

        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }

    func testRemoveWorkDirectoryToleratesAMissingDirectory() throws {
        let root = try scratchRoot()
        UpdateChecker.removeWorkDirectory(root.appendingPathComponent("gone", isDirectory: true))
    }

    // MARK: - Sweeping leftovers from earlier runs

    func testSweepRemovesWorkDirectoriesOlderThanTheCutoff() throws {
        let root = try scratchRoot()
        let now = Date()
        let old = try makeDir("MishMailUpdate-old", in: root,
                              created: now.addingTimeInterval(-7_200))

        UpdateChecker.sweepStaleWorkDirectories(in: root, olderThan: 3_600, now: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    func testSweepKeepsARecentWorkDirectory() throws {
        let root = try scratchRoot()
        let now = Date()
        // An install running in another window of the same app, or this one's
        // own directory: deleting it mid-flight would break the install.
        let fresh = try makeDir("MishMailUpdate-fresh", in: root,
                                created: now.addingTimeInterval(-60))

        UpdateChecker.sweepStaleWorkDirectories(in: root, olderThan: 3_600, now: now)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testSweepIgnoresEverythingElseInTheTempDirectory() throws {
        let root = try scratchRoot()
        let now = Date()
        let other = try makeDir("SomeoneElsesCache", in: root,
                                created: now.addingTimeInterval(-90_000))
        let file = root.appendingPathComponent("MishMailUpdate-notadirectory")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path,
                                                     contents: Data("x".utf8)))
        try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-90_000)],
                                              ofItemAtPath: file.path)

        UpdateChecker.sweepStaleWorkDirectories(in: root, olderThan: 3_600, now: now)

        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "only directories the update pipeline creates should be swept")
    }

    // MARK: - Failures inside the pipeline

    func testAnUnreadableArchiveLeavesNoWorkDirectoryBehind() async throws {
        let root = try scratchRoot()
        let notAZip = root.appendingPathComponent("download.tmp")
        XCTAssertTrue(FileManager.default.createFile(atPath: notAZip.path,
                                                     contents: Data("not a zip".utf8)))

        do {
            _ = try await UpdateChecker.stageAndVerify(
                downloadedZip: notAZip,
                assetName: "MishMail-1.0.0.zip",
                checksumURL: nil,
                expectedVersion: "1.0.0",
                runningAppURL: Bundle.main.bundleURL,
                workRoot: root)
            XCTFail("a corrupt archive should not verify")
        } catch {}

        XCTAssertTrue(try workDirectories(in: root).isEmpty,
                      "a failed install must not leave its scratch directory behind")
    }

    func testARejectedUpdateLeavesNoWorkDirectoryBehind() async throws {
        guard let app = UpdateVerifySmokeTests.builtAppURL() else {
            throw XCTSkip("No built MishMail app in DerivedData; run `make build` first")
        }
        let root = try scratchRoot()
        let zip = root.appendingPathComponent("download.tmp")
        let pack = Process()
        pack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        pack.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
        try pack.run()
        pack.waitUntilExit()
        XCTAssertEqual(pack.terminationStatus, 0, "ditto zip failed")

        do {
            // Whatever the built app's version is, it isn't this one — the
            // pipeline gets as far as extracting and then rejects it.
            _ = try await UpdateChecker.stageAndVerify(
                downloadedZip: zip,
                assetName: "MishMail-99.99.99.zip",
                checksumURL: nil,
                expectedVersion: "99.99.99",
                runningAppURL: app,
                workRoot: root)
            XCTFail("a version-mismatched update should not verify")
        } catch {}

        XCTAssertTrue(try workDirectories(in: root).isEmpty,
                      "a rejected update must not leave its extracted copy behind")
    }

    private func workDirectories(in root: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("MishMailUpdate-") }
    }
}
