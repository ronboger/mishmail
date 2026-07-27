import XCTest

/// The in-place install path: where the update goes, whether a stored grant
/// still applies, and that the swap is all-or-nothing.
final class UpdateInstallerTests: XCTestCase {

    // MARK: - Install directory

    func testInstallDirectoryIsTheAppsParent() {
        let app = URL(fileURLWithPath: "/Applications/MishMail.app")
        XCTAssertEqual(UpdateInstaller.installDirectory(for: app).path, "/Applications")
    }

    func testInstallDirectoryFollowsAMovedApp() {
        let app = URL(fileURLWithPath: "/Users/someone/Desktop/MishMail.app")
        XCTAssertEqual(UpdateInstaller.installDirectory(for: app).path,
                       "/Users/someone/Desktop")
    }

    // MARK: - Grant matching

    func testGrantMatchesSameFolder() {
        let dir = URL(fileURLWithPath: "/Applications")
        XCTAssertTrue(UpdateInstaller.grantMatches(dir, installDirectory: dir))
        // Trailing slashes and "." components are the same folder.
        XCTAssertTrue(UpdateInstaller.grantMatches(
            URL(fileURLWithPath: "/Applications/"), installDirectory: dir))
        XCTAssertTrue(UpdateInstaller.grantMatches(
            URL(fileURLWithPath: "/Applications/./"), installDirectory: dir))
    }

    func testGrantDoesNotMatchAnotherFolder() {
        // A grant for the parent of an app that has since moved must not be
        // reused — it would install over a bundle nobody is running.
        XCTAssertFalse(UpdateInstaller.grantMatches(
            URL(fileURLWithPath: "/Applications"),
            installDirectory: URL(fileURLWithPath: "/Users/someone/Desktop")))
        XCTAssertFalse(UpdateInstaller.grantMatches(
            URL(fileURLWithPath: "/Applications/Utilities"),
            installDirectory: URL(fileURLWithPath: "/Applications")))
    }

    // MARK: - Stored grant

    func testResolveGrantWithoutABookmarkIsNil() throws {
        let defaults = try scratchDefaults()
        XCTAssertNil(UpdateInstaller.resolveGrant(
            installDirectory: URL(fileURLWithPath: "/Applications"), defaults: defaults))
    }

    func testUnresolvableBookmarkIsDiscardedSoTheNextTryReprompts() throws {
        let defaults = try scratchDefaults()
        defaults.set(Data("not a bookmark".utf8), forKey: UpdateInstaller.bookmarkKey)

        XCTAssertNil(UpdateInstaller.resolveGrant(
            installDirectory: URL(fileURLWithPath: "/Applications"), defaults: defaults))
        XCTAssertNil(defaults.data(forKey: UpdateInstaller.bookmarkKey),
                     "a bookmark that can't resolve should be dropped, not retried forever")
    }

    // MARK: - The swap

    func testSwapReplacesTheInstalledBundle() throws {
        let fm = FileManager.default
        let work = try scratchDirectory()
        defer { try? fm.removeItem(at: work) }

        let installed = try stubApp(named: "MishMail.app", in: work, marker: "0.4.0")
        let staging = work.appendingPathComponent("staging", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let update = try stubApp(named: "MishMail.app", in: staging, marker: "0.4.1")

        try UpdateInstaller.swap(newApp: update, onto: installed)

        XCTAssertEqual(try marker(of: installed), "0.4.1")
        XCTAssertFalse(fm.fileExists(atPath: update.path),
                       "replaceItemAt consumes the staged bundle")
    }

    func testFailedSwapLeavesTheRunningAppIntact() throws {
        let fm = FileManager.default
        let work = try scratchDirectory()
        defer { try? fm.removeItem(at: work) }

        let installed = try stubApp(named: "MishMail.app", in: work, marker: "0.4.0")
        let missing = work.appendingPathComponent("nothing-here/MishMail.app")

        XCTAssertThrowsError(try UpdateInstaller.swap(newApp: missing, onto: installed))
        XCTAssertEqual(try marker(of: installed), "0.4.0",
                       "a failed install must leave the app the user is running alone")
    }

    func testSwapLeavesTheInstalledBundleUnquarantined() throws {
        let fm = FileManager.default
        let work = try scratchDirectory()
        defer { try? fm.removeItem(at: work) }

        let installed = try stubApp(named: "MishMail.app", in: work, marker: "0.4.0")
        let staging = work.appendingPathComponent("staging", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let update = try stubApp(named: "MishMail.app", in: staging, marker: "0.4.1")
        // Whatever tagged it, the installed app must not carry the attribute:
        // Gatekeeper refuses to launch a quarantined un-notarized build, so a
        // tag surviving the swap would break the relaunch outright.
        try tagQuarantined(update)
        XCTAssertTrue(isQuarantined(update), "fixture should start tagged")

        try UpdateInstaller.swap(newApp: update, onto: installed)

        XCTAssertFalse(isQuarantined(installed))
    }

    func testClearQuarantineToleratesAnUntaggedBundle() throws {
        let work = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let app = try stubApp(named: "MishMail.app", in: work, marker: "0.4.0")
        // Nothing in the download path tags the bundle, so clearing is
        // normally a no-op — one that must not blow up.
        UpdateInstaller.clearQuarantine(app)
        XCTAssertEqual(try marker(of: app), "0.4.0")
    }

    // MARK: - Relauncher

    func testRelauncherIsResolvedInsideTheBundle() {
        // Resolved against the bundle being installed, not the running one:
        // after the swap that path holds the new copy.
        XCTAssertEqual(
            UpdateInstaller.relauncherURL(inside:
                URL(fileURLWithPath: "/Applications/MishMail.app")).path,
            "/Applications/MishMail.app/Contents/Library/MishMailRelauncher.app")
    }

    /// The shipped app must actually carry the relauncher — without it the
    /// update installs and then can't restart, which is the whole bug this
    /// exists to fix. Skipped cleanly when there's no build to look at.
    func testBuiltAppEmbedsTheRelauncher() throws {
        guard let app = builtAppURL() else {
            throw XCTSkip("No built MishMail app in DerivedData; run `make build` first")
        }
        let helper = UpdateInstaller.relauncherURL(inside: app)
        XCTAssertTrue(FileManager.default.fileExists(atPath: helper.path),
                      "expected an embedded relauncher at \(helper.path)")
        // A bundle without its executable would launch and do nothing.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: helper.appendingPathComponent("Contents/MacOS/MishMailRelauncher").path))
    }

    /// Prefer Release, then Debug, resolved from this source file so the
    /// working directory under xcodebuild doesn't matter.
    private func builtAppURL() -> URL? {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for rel in ["build/dd.noindex/Build/Products/Release/MishMail.app",
                    "build/dd.noindex/Build/Products/Debug/MishMail Debug.app"] {
            let url = repo.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: - Translocation

    func testTranslocatedAppIsDetected() {
        XCTAssertTrue(UpdateInstaller.isTranslocated(URL(fileURLWithPath:
            "/private/var/folders/ab/xyz/d/AppTranslocation/1B2C-3D/d/MishMail.app")))
        XCTAssertFalse(UpdateInstaller.isTranslocated(
            URL(fileURLWithPath: "/Applications/MishMail.app")))
    }

    // MARK: - Fixtures

    private func scratchDefaults() throws -> UserDefaults {
        let name = "UpdateInstallerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }

    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A directory that looks enough like an app bundle for a swap, carrying a
    /// version marker so the test can tell the two apart afterwards.
    private func stubApp(named name: String, in directory: URL,
                         marker: String) throws -> URL {
        let app = directory.appendingPathComponent(name, isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try marker.write(to: contents.appendingPathComponent("version.txt"),
                         atomically: true, encoding: .utf8)
        return app
    }

    private func tagQuarantined(_ url: URL) throws {
        let value = "0001;00000000;test;\(UUID().uuidString)"
        let ok = value.withCString {
            setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, 0)
        }
        try XCTSkipIf(ok != 0, "filesystem rejected the quarantine xattr")
    }

    private func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }

    private func marker(of app: URL) throws -> String {
        try String(contentsOf: app.appendingPathComponent("Contents/version.txt"),
                   encoding: .utf8)
    }
}
