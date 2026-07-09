import XCTest

/// Smoke the update zip → extract → signature path against a real codesigned
/// app bundle when DerivedData has one (skipped cleanly otherwise).
final class UpdateVerifySmokeTests: XCTestCase {

    func testVerifyBuiltAppIfPresent() throws {
        guard let app = Self.builtAppURL() else {
            throw XCTSkip("No built PerfectMail app in DerivedData; run `make build` first")
        }
        // The Debug app is ad-hoc signed; SecStaticCodeCheckValidity should
        // still accept a structurally valid signature.
        XCTAssertNoThrow(try UpdateChecker.verifyCodeSignature(of: app))
    }

    func testZipRoundTripFindsAndVerifiesApp() throws {
        guard let app = Self.builtAppURL() else {
            throw XCTSkip("No built PerfectMail app in DerivedData; run `make build` first")
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("pm-zip-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        let zip = work.appendingPathComponent("release.zip")
        let extract = work.appendingPathComponent("extract", isDirectory: true)
        try fm.createDirectory(at: extract, withIntermediateDirectories: true)

        // Pack the .app the same way `make release` does (ditto zip).
        let pack = Process()
        pack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        pack.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
        try pack.run()
        pack.waitUntilExit()
        XCTAssertEqual(pack.terminationStatus, 0, "ditto zip failed")

        try UpdateChecker.unzip(zip, into: extract)
        let found = UpdateChecker.findApp(in: extract)
        XCTAssertNotNil(found, "unzipped archive should contain an .app")
        // Debug app is "PerfectMail Debug.app"; findApp falls back to any .app.
        XCTAssertEqual(found?.pathExtension, "app")
        try UpdateChecker.verifyCodeSignature(of: found!)
    }

    /// Prefer Release, then Debug products under the project's DerivedData.
    /// Resolve from this source file so cwd (often not the repo root under
    /// xcodebuild) doesn't matter.
    private static func builtAppURL() -> URL? {
        // …/Tests/PerfectMailTests/ThisFile.swift → repo root
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            "build/dd.noindex/Build/Products/Release/PerfectMail.app",
            "build/dd.noindex/Build/Products/Debug/PerfectMail Debug.app",
            "build/Build/Products/Release/PerfectMail.app",
            "build/Build/Products/Debug/PerfectMail Debug.app",
        ]
        for rel in candidates {
            let url = repo.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
