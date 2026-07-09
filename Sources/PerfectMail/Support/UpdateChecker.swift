import Foundation
import AppKit
import Security

/// Checks GitHub Releases for a newer version of the app. The app is
/// sandboxed, so there is no in-place auto-install: "Update App" downloads
/// the release zip, verifies the embedded app's code signature, then reveals
/// it in Finder so the user can drag it into Applications. Falls back to the
/// release page if verification fails or no zip asset is published.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let repo = "ronboger/perfectmail"

    struct Release {
        let version: String       // tag with any leading "v" stripped
        let htmlURL: URL          // release page
        let assetURL: URL?        // direct .dmg/.zip download when published
        let notes: String
    }

    /// Set only when the latest release is newer than the running version.
    @Published var available: Release?
    @Published var checking = false
    @Published var installing = false
    @Published var lastChecked: Date?
    /// Outcome of an explicit check ("You're up to date.", errors).
    @Published var status: String?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private var timer: Timer?
    private static let lastCheckKey = "updates.lastCheckAt"

    /// Quiet daily checks: once now if a day has passed, then hourly ticks
    /// that re-check when the window lapses — a mail app stays open for
    /// days, so launch-only checking would never surface anything.
    func startPeriodicChecks() {
        checkIfDue()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { _ in
            Task { @MainActor in UpdateChecker.shared.checkIfDue() }
        }
    }

    private func checkIfDue() {
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        Task { await check(quietly: true) }
    }

    func check(quietly: Bool = false) async {
        // Quiet checks yield to one already in flight; an explicit click
        // still runs (and reports) even if a quiet check is racing it.
        guard !(checking && quietly) else { return }
        checking = true
        defer { checking = false; lastChecked = Date() }
        do {
            var req = URLRequest(
                url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                if code == 404 {
                    // Genuinely no releases published yet.
                    available = nil
                    if !quietly { status = "No releases have been published on GitHub yet." }
                } else if !quietly {
                    // Rate limit / server hiccup: keep any known update.
                    status = "GitHub returned an error (HTTP \(code)). Try again later."
                }
                return
            }
            // The 24h throttle only counts checks that actually reached
            // GitHub — an offline launch shouldn't burn the day's slot.
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            struct GHRelease: Decodable {
                struct Asset: Decodable { let name: String; let browser_download_url: URL }
                let tag_name: String
                let html_url: URL
                let body: String?
                let assets: [Asset]
            }
            let gh = try JSONDecoder().decode(GHRelease.self, from: data)
            let version = gh.tag_name.hasPrefix("v")
                ? String(gh.tag_name.dropFirst()) : gh.tag_name
            // Prefer zip (what `make release` publishes); dmg is accepted too
            // but signature verification only runs for zip → .app.
            let asset = gh.assets.first { $0.name.hasSuffix(".zip") }
                ?? gh.assets.first { $0.name.hasSuffix(".dmg") }
            if Self.isNewer(version, than: currentVersion) {
                available = Release(version: version, htmlURL: gh.html_url,
                                    assetURL: asset?.browser_download_url,
                                    notes: gh.body ?? "")
                status = nil
            } else {
                available = nil
                if !quietly { status = "You're up to date." }
            }
        } catch {
            if !quietly { status = error.localizedDescription }
        }
    }

    /// Numeric dotted-version compare: "0.2.0" is newer than "0.1.9".
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        let b = current.split(separator: ".").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Download the release zip, verify the embedded app's code signature, and
    /// reveal it in Finder. Falls back to the GitHub release page when there is
    /// no zip asset, the download fails, or the signature is invalid — never
    /// silently install an unverified binary.
    func openUpdate() {
        guard let available else { return }
        Task { await installOrOpenReleasePage(available) }
    }

    /// Open the release notes page without downloading (user can inspect first).
    func openReleasePage() {
        guard let available else { return }
        NSWorkspace.shared.open(available.htmlURL)
    }

    private func installOrOpenReleasePage(_ release: Release) async {
        guard !installing else { return }
        // Zip only: we can extract an .app and verify its signature. A .dmg
        // would need to be mounted; fall back to the release page for those.
        guard let assetURL = release.assetURL,
              assetURL.pathExtension.lowercased() == "zip"
                || assetURL.lastPathComponent.lowercased().hasSuffix(".zip") else {
            NSWorkspace.shared.open(release.htmlURL)
            return
        }
        installing = true
        status = "Downloading PerfectMail \(release.version)…"
        defer { installing = false }
        do {
            let appURL = try await Self.downloadAndVerifyApp(from: assetURL)
            status = "Verified signature for PerfectMail \(release.version). Drag it into Applications to install."
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
        } catch {
            status = "Couldn't verify the update (\(error.localizedDescription)). Opening the release page instead."
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    enum UpdateError: LocalizedError {
        case badHTTP(Int)
        case noAppInArchive
        case invalidSignature(OSStatus)
        case unzipFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .badHTTP(let code): return "download failed (HTTP \(code))"
            case .noAppInArchive: return "release archive contained no PerfectMail.app"
            case .invalidSignature(let s): return "code signature invalid (OSStatus \(s))"
            case .unzipFailed(let c): return "unzip failed (exit \(c))"
            }
        }
    }

    /// Downloads `zipURL`, extracts it under a unique temp directory, finds
    /// `PerfectMail.app`, and checks its code signature. Returns the app URL
    /// on success. Nonisolated so the network work can run off the main actor.
    nonisolated static func downloadAndVerifyApp(from zipURL: URL) async throws -> URL {
        let (tempFile, resp) = try await URLSession.shared.download(from: zipURL)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw UpdateError.badHTTP(code) }

        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("PerfectMailUpdate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let zipPath = work.appendingPathComponent("release.zip")
        // download(from:) leaves a file in a system temp location; move it
        // into our work dir so cleanup is one removeItem.
        if fm.fileExists(atPath: zipPath.path) { try fm.removeItem(at: zipPath) }
        try fm.moveItem(at: tempFile, to: zipPath)

        let extractDir = work.appendingPathComponent("extract", isDirectory: true)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try unzip(zipPath, into: extractDir)

        guard let appURL = findApp(in: extractDir) else { throw UpdateError.noAppInArchive }
        try verifyCodeSignature(of: appURL)
        return appURL
    }

    /// `ditto -x -k` is the system-supported way to expand a zip while
    /// preserving macOS resource forks / quarantine attributes.
    nonisolated static func unzip(_ zip: URL, into destination: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", zip.path, destination.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw UpdateError.unzipFailed(proc.terminationStatus)
        }
    }

    /// Depth-first search for `PerfectMail.app` (or any single `.app` if the
    /// archive uses a versioned name).
    nonisolated static func findApp(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var fallback: URL?
        for case let url as URL in enumerator {
            guard url.pathExtension == "app" else { continue }
            if url.lastPathComponent == "PerfectMail.app" { return url }
            if fallback == nil { fallback = url }
            enumerator.skipDescendants()
        }
        return fallback
    }

    /// Structural + nested code-signature check via Security.framework (no
    /// external process). Rejects a corrupted or unsigned payload; does not
    /// by itself prove Developer ID / notarization (Gatekeeper still runs on
    /// first open of a quarantined app).
    nonisolated static func verifyCodeSignature(of appURL: URL) throws {
        var staticCode: SecStaticCode?
        let create = SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode)
        guard create == errSecSuccess, let staticCode else {
            throw UpdateError.invalidSignature(create)
        }
        // Nested code covers the embedded GRDB framework etc.
        let flags = SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSCheckAllArchitectures)
        let check = SecStaticCodeCheckValidity(staticCode, flags, nil)
        guard check == errSecSuccess else {
            throw UpdateError.invalidSignature(check)
        }
    }
}
