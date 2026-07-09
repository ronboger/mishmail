import Foundation
import AppKit
import Security
import CryptoKit

/// Checks GitHub Releases for a newer version of the app. The app is
/// sandboxed, so there is no in-place auto-install: "Update App" downloads
/// the release zip, verifies SHA-256 (when published), code signature, Team ID
/// continuity, and notarization for Developer ID builds — then reveals the app
/// in Finder. Falls back to the release page if verification fails.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let repo = "ronboger/perfectmail"

    struct Release {
        let version: String       // tag with any leading "v" stripped
        let htmlURL: URL          // release page
        let assetURL: URL?        // direct .zip download when published
        let checksumURL: URL?     // SHA256SUMS (or *.sha256) companion asset
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
                    available = nil
                    if !quietly { status = "No releases have been published on GitHub yet." }
                } else if !quietly {
                    status = "GitHub returned an error (HTTP \(code)). Try again later."
                }
                return
            }
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
            let zipAsset = gh.assets.first { $0.name.hasSuffix(".zip") }
            let checksumAsset = Self.pickChecksumAsset(from: gh.assets.map(\.name),
                                                       urls: gh.assets.map(\.browser_download_url),
                                                       zipName: zipAsset?.name)
            if Self.isNewer(version, than: currentVersion) {
                available = Release(version: version, htmlURL: gh.html_url,
                                    assetURL: zipAsset?.browser_download_url,
                                    checksumURL: checksumAsset,
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

    /// Prefer `SHA256SUMS`, then `PerfectMail-*.zip.sha256`.
    nonisolated static func pickChecksumAsset(from names: [String], urls: [URL],
                                              zipName: String?) -> URL? {
        precondition(names.count == urls.count)
        if let i = names.firstIndex(where: { $0.uppercased() == "SHA256SUMS"
                                              || $0.uppercased() == "SHA256SUMS.TXT" }) {
            return urls[i]
        }
        if let zipName,
           let i = names.firstIndex(where: { $0 == "\(zipName).sha256" || $0 == "\(zipName).SHA256" }) {
            return urls[i]
        }
        return names.enumerated().first { $0.element.lowercased().hasSuffix(".sha256") }.map { urls[$0.offset] }
    }

    func openUpdate() {
        guard let available else { return }
        Task { await installOrOpenReleasePage(available) }
    }

    func openReleasePage() {
        guard let available else { return }
        NSWorkspace.shared.open(available.htmlURL)
    }

    private func installOrOpenReleasePage(_ release: Release) async {
        guard !installing else { return }
        guard let assetURL = release.assetURL else {
            NSWorkspace.shared.open(release.htmlURL)
            return
        }
        installing = true
        status = "Downloading PerfectMail \(release.version)…"
        defer { installing = false }
        do {
            let result = try await Self.downloadAndVerifyApp(
                from: assetURL,
                checksumURL: release.checksumURL,
                runningAppURL: Bundle.main.bundleURL
            )
            var msg = "Verified PerfectMail \(release.version)"
            if result.checksumVerified { msg += " (SHA-256)" }
            if let team = result.teamID { msg += " · Team \(team)" }
            if result.notarized { msg += " · notarized" }
            msg += ". Drag it into Applications to install."
            status = msg
            NSWorkspace.shared.activateFileViewerSelecting([result.appURL])
        } catch {
            status = "Couldn't verify the update (\(error.localizedDescription)). Opening the release page instead."
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    struct VerifyResult {
        let appURL: URL
        let checksumVerified: Bool
        let teamID: String?
        let notarized: Bool
    }

    enum UpdateError: LocalizedError, Equatable {
        case badHTTP(Int)
        case noAppInArchive
        case invalidSignature(OSStatus)
        case unzipFailed(Int32)
        case checksumMismatch
        case checksumMissingForAsset
        case teamMismatch(expected: String, found: String?)
        case adHocDowngrade
        case notDeveloperID
        case notNotarized

        var errorDescription: String? {
            switch self {
            case .badHTTP(let code): return "download failed (HTTP \(code))"
            case .noAppInArchive: return "release archive contained no PerfectMail.app"
            case .invalidSignature(let s): return "code signature invalid (OSStatus \(s))"
            case .unzipFailed(let c): return "unzip failed (exit \(c))"
            case .checksumMismatch: return "SHA-256 did not match the published checksum"
            case .checksumMissingForAsset: return "checksum file did not list this zip"
            case .teamMismatch(let exp, let found):
                return "Team ID mismatch (running \(exp), update \(found ?? "ad-hoc"))"
            case .adHocDowngrade: return "refusing ad-hoc update while running a team-signed build"
            case .notDeveloperID: return "update is not Developer ID signed"
            case .notNotarized: return "update is not notarized"
            }
        }
    }

    /// Full install pipeline: download zip → optional SHA-256 → extract →
    /// signature + Team ID + notarization policy → quarantined app URL.
    nonisolated static func downloadAndVerifyApp(
        from zipURL: URL,
        checksumURL: URL?,
        runningAppURL: URL
    ) async throws -> VerifyResult {
        let (tempFile, resp) = try await URLSession.shared.download(from: zipURL)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw UpdateError.badHTTP(code) }

        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("PerfectMailUpdate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let zipPath = work.appendingPathComponent("release.zip")
        if fm.fileExists(atPath: zipPath.path) { try fm.removeItem(at: zipPath) }
        try fm.moveItem(at: tempFile, to: zipPath)

        var checksumVerified = false
        if let checksumURL {
            let (sumsData, sumsResp) = try await URLSession.shared.data(from: checksumURL)
            let sumsCode = (sumsResp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(sumsCode) else { throw UpdateError.badHTTP(sumsCode) }
            let text = String(data: sumsData, encoding: .utf8) ?? ""
            let assetName = zipURL.lastPathComponent
            guard let expected = parseChecksum(text, assetName: assetName) else {
                throw UpdateError.checksumMissingForAsset
            }
            let actual = try sha256Hex(ofFile: zipPath)
            guard actual == expected.lowercased() else { throw UpdateError.checksumMismatch }
            checksumVerified = true
        }

        let extractDir = work.appendingPathComponent("extract", isDirectory: true)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try unzip(zipPath, into: extractDir)

        guard let appURL = findApp(in: extractDir) else { throw UpdateError.noAppInArchive }
        try verifyCodeSignature(of: appURL)
        let trust = try evaluateTrust(updateApp: appURL, runningApp: runningAppURL,
                                      officialRelease: checksumVerified)
        // Gatekeeper still sees this as internet-downloaded content.
        markQuarantined(appURL)
        return VerifyResult(appURL: appURL, checksumVerified: checksumVerified,
                            teamID: trust.teamID, notarized: trust.notarized)
    }

    // MARK: - Checksums

    /// SHA-256 hex of a file (streaming via `Data(contentsOf:)` is fine for
    /// release zips; they're tens of MB at most).
    nonisolated static func sha256Hex(ofFile url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Parses GNU `SHA256SUMS` (`<hash>  <name>` / `<hash> *<name>`) or a bare
    /// 64-char hex line (single-asset `.sha256` files).
    nonisolated static func parseChecksum(_ text: String, assetName: String) -> String? {
        let wanted = assetName.lowercased()
        var bareHex: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map { String($0) }
            guard let first = tokens.first else { continue }
            let hash = first.lowercased()
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { continue }
            if tokens.count == 1 {
                bareHex = hash
                continue
            }
            let name = tokens[1].trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            let base = URL(fileURLWithPath: name).lastPathComponent.lowercased()
            if base == wanted || name.lowercased() == wanted { return hash }
        }
        return bareHex
    }

    // MARK: - Unzip / find

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

    // MARK: - Code signature / trust

    nonisolated static func verifyCodeSignature(of appURL: URL) throws {
        var staticCode: SecStaticCode?
        let create = SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode)
        guard create == errSecSuccess, let staticCode else {
            throw UpdateError.invalidSignature(create)
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSCheckAllArchitectures)
        let check = SecStaticCodeCheckValidity(staticCode, flags, nil)
        guard check == errSecSuccess else {
            throw UpdateError.invalidSignature(check)
        }
    }

    /// Team ID from a bundle's code signature (`nil` = ad-hoc / unsigned team).
    nonisolated static func teamIdentifier(of appURL: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// True when the binary satisfies Apple's `notarized` requirement.
    nonisolated static func isNotarized(_ appURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("notarized" as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSCheckAllArchitectures)
        return SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess
    }

    /// True when signed as Developer ID Application (not just "valid signature").
    nonisolated static func isDeveloperID(_ appURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        // Leaf has Developer ID Application OID; intermediate is Developer ID CA.
        let reqStr = """
            anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
            and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
            """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(reqStr as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSCheckAllArchitectures)
        return SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess
    }

    struct TrustOutcome {
        let teamID: String?
        let notarized: Bool
    }

    /// Trust rules (open-source friendly — no embedded secrets / no hard-coded
    /// Team ID):
    /// - Structural signature already checked by the caller.
    /// - **Team continuity**: if the running app has a Team ID, the update must
    ///   share it (blocks a foreign Developer ID on a compromised release).
    /// - **No ad-hoc downgrade** from a team-signed install.
    /// - **Developer ID updates must be notarized** (whether or not a checksum
    ///   was published) — covers ad-hoc/source installs upgrading to a public
    ///   binary and official Developer ID releases.
    /// - Apple Development / ad-hoc self-updates (same team or both ad-hoc) are
    ///   allowed so personal `make release` still works; SHA-256 is the main
    ///   integrity check for those.
    nonisolated static func evaluateTrust(updateApp: URL, runningApp: URL,
                                          officialRelease: Bool) throws -> TrustOutcome {
        let runningTeam = teamIdentifier(of: runningApp)
        let updateTeam = teamIdentifier(of: updateApp)
        let notarized = isNotarized(updateApp)
        let developerID = isDeveloperID(updateApp)
        // officialRelease reserved for callers that want stricter future
        // policy (e.g. requiring checksums); team rules below are enough today.
        _ = officialRelease

        if let runningTeam {
            guard let updateTeam else { throw UpdateError.adHocDowngrade }
            guard updateTeam == runningTeam else {
                throw UpdateError.teamMismatch(expected: runningTeam, found: updateTeam)
            }
        }

        if developerID {
            guard notarized else { throw UpdateError.notNotarized }
        }

        return TrustOutcome(teamID: updateTeam, notarized: notarized)
    }

    /// Same quarantine tagging the attachment path uses.
    nonisolated static func markQuarantined(_ url: URL) {
        let stamp = String(format: "%08x", UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970)))
        let value = "0001;\(stamp);PerfectMail;\(UUID().uuidString)"
        value.withCString { cstr in
            _ = setxattr(url.path, "com.apple.quarantine", cstr, strlen(cstr), 0, 0)
        }
    }
}
