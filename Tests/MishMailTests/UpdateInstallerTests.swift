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

    // MARK: - Relaunch script

    func testRelaunchScriptWaitsForThisProcessThenOpensTheApp() {
        let script = UpdateInstaller.relaunchScript(pid: 4242,
                                                    appPath: "/Applications/MishMail.app")
        // Waiting matters: asking LaunchServices for a second instance of our
        // own bundle fails while we're still running (-10810).
        XCTAssertTrue(script.contains("kill -0 4242"))
        XCTAssertTrue(script.contains("open '/Applications/MishMail.app'"))
        // Bounded, so a process that never exits doesn't leave a shell spinning.
        XCTAssertTrue(script.contains("-lt 300"))
    }

    func testRelaunchScriptQuotesAwkwardPaths() {
        let spaced = UpdateInstaller.relaunchScript(
            pid: 1, appPath: "/Users/someone/My Apps/MishMail.app")
        XCTAssertTrue(spaced.contains("open '/Users/someone/My Apps/MishMail.app'"),
                      "a space in the path must not split the argument")
        // An apostrophe would otherwise close the quote and let the rest of
        // the path run as commands.
        XCTAssertEqual(UpdateInstaller.shellQuoted("/Users/o'brien/MishMail.app"),
                       "'/Users/o'\\''brien/MishMail.app'")
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
