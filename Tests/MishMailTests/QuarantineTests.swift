import XCTest

/// The relauncher's quarantine stripping.
///
/// This lives in the helper rather than the app because the sandbox denies
/// `removexattr` on `com.apple.quarantine` — silently, which is how three
/// releases shipped a "clear quarantine" step that never cleared anything.
/// These tests run in the (unsandboxed) test runner, the same condition the
/// helper is signed for.
final class QuarantineTests: XCTestCase {

    func testStripsTheRootAndEverythingUnderIt() throws {
        let bundle = try stubBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        // A nested app bundle is the case that actually broke: the embedded
        // relauncher is launched in its own right, so a tag it keeps makes the
        // whole update unopenable.
        let nested = bundle.appendingPathComponent("Contents/Library/Helper.app")
        let deep = nested.appendingPathComponent("Contents/MacOS/Helper")
        for url in [bundle, nested, deep] {
            try tag(url)
            XCTAssertTrue(isTagged(url), "fixture should start tagged: \(url.lastPathComponent)")
        }

        Quarantine.strip(from: bundle)

        for url in [bundle, nested, deep] {
            XCTAssertFalse(isTagged(url), "still tagged: \(url.path)")
        }
    }

    func testStrippingAnUntaggedBundleIsANoOp() throws {
        let bundle = try stubBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        // The helper also runs when the install failed and the untouched old
        // bundle is still in place; that must not be an error.
        Quarantine.strip(from: bundle)
        XCTAssertFalse(isTagged(bundle))
    }

    // MARK: - Fixtures

    /// An .app-shaped tree with a nested .app inside it.
    private func stubBundle() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quarantine-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("MishMail.app", isDirectory: true)
        let nestedMacOS = app.appendingPathComponent("Contents/Library/Helper.app/Contents/MacOS",
                                                     isDirectory: true)
        try FileManager.default.createDirectory(at: nestedMacOS, withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: nestedMacOS.appendingPathComponent("Helper"))
        return app
    }

    private func tag(_ url: URL) throws {
        let value = "0081;00000000;test;\(UUID().uuidString)"
        let ok = value.withCString {
            setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, XATTR_NOFOLLOW)
        }
        try XCTSkipIf(ok != 0, "filesystem rejected the quarantine xattr")
    }

    private func isTagged(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }
}
