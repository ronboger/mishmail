import Foundation
import AppKit
import Security
import CryptoKit

/// Checks GitHub Releases for a newer version of the app. "Install and
/// Relaunch" downloads the release zip, verifies SHA-256 (when published),
/// code signature, Team ID continuity, and notarization for Developer ID
/// builds, then hands the verified bundle to `UpdateInstaller`, which swaps it
/// over the running app and restarts. Verification failures open the release
/// page; install failures fall back to revealing the app in Finder.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let repo = "ronboger/mishmail"

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

    /// Graceful-shutdown hook the app installs at launch, so an in-place
    /// install can close the database before the relaunched instance opens
    /// it. A closure rather than a direct `MailStore` call because the unit
    /// test target compiles this file without the app's store.
    var prepareForQuit: (() async -> Void)?
    /// Whether a compose window is open, for the same reason and by the same
    /// mechanism — the restart asks first when a draft is on screen.
    var hasOpenDraft: (() -> Bool)?

    private var timer: Timer?
    private static let lastCheckKey = "updates.lastCheckAt"

    /// Quiet checks: always once at launch, then hourly ticks that re-check
    /// when the daily window lapses.
    ///
    /// Launch used to go through the same daily gate, which meant relaunching
    /// into a brand-new release showed nothing — the timestamp had been
    /// written hours earlier and survives in the app's preferences. A launch
    /// is rare and one request is cheap, so it always looks; the hourly tick
    /// exists for the opposite case, a mail app left open for days.
    func startPeriodicChecks() {
        Task { await check(quietly: true) }
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
        // still runs (and reports) even if a quiet check is racing it. Nothing
        // checks during an install — it would overwrite the progress status
        // and could clear `available` out from under the running install.
        guard !(checking && quietly), !installing else { return }
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

    /// Prefer `SHA256SUMS`, then `MishMail-*.zip.sha256`.
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
        // Claim the flow before the confirmation runs: a modal spins its own
        // run loop, so a second click during it would otherwise pass the
        // guard above and stack another alert.
        installing = true
        defer { installing = false }
        // Remembered so a draft opened *during* the download still gets its
        // own question: one answer shouldn't cover a draft that didn't exist
        // when it was given.
        let answeredWithDraftOpen = hasOpenDraft?() == true
        guard confirmRestartOverOpenDraft(release) else {
            status = "Update cancelled."
            return
        }
        status = "Downloading MishMail \(release.version)…"

        let runningApp = Bundle.main.bundleURL
        let verified: VerifyResult
        do {
            verified = try await Self.downloadAndVerifyApp(
                from: assetURL,
                checksumURL: release.checksumURL,
                expectedVersion: release.version,
                runningAppURL: runningApp
            )
        } catch {
            status = "Couldn't verify the update (\(error.localizedDescription)). Opening the release page instead."
            NSWorkspace.shared.open(release.htmlURL)
            return
        }
        await install(verified, release: release, runningApp: runningApp,
                      draftAlreadyAnswered: answeredWithDraftOpen)
    }

    /// Restarting is disruptive in a way an ordinary button click is not, so
    /// an open draft gets a say first. Compose autosaves on a debounce and
    /// termination does not flush a save that is still pending, so the last
    /// few seconds of typing genuinely can be lost.
    private func confirmRestartOverOpenDraft(_ release: Release) -> Bool {
        guard hasOpenDraft?() == true else { return true }
        let alert = NSAlert()
        alert.messageText = "Install MishMail \(release.version) and restart?"
        alert.informativeText = "You have a draft open. It saves to Gmail as you type, "
            + "but anything typed in the last moment could be lost."
        alert.addButton(withTitle: "Install and Restart")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Swap the verified bundle over the running app and restart. Up to the
    /// swap, every failure degrades to the old reveal-in-Finder path instead
    /// of a dead end — the verified copy is still sitting in the temp
    /// directory.
    private func install(_ verified: VerifyResult, release: Release, runningApp: URL,
                         draftAlreadyAnswered: Bool) async {
        // A quarantined app launched from where it was downloaded runs off a
        // read-only App Translocation mount, so there is no install directory
        // to swap into until the user puts it somewhere real.
        guard !UpdateInstaller.isTranslocated(runningApp) else {
            revealForManualInstall(
                verified, reason: "MishMail is running from a temporary location.")
            return
        }

        let installDir = UpdateInstaller.installDirectory(for: runningApp)
        let grant: URL
        do {
            grant = try UpdateInstaller.resolveGrant(installDirectory: installDir)
                ?? UpdateInstaller.requestGrant(installDirectory: installDir)
        } catch {
            revealForManualInstall(verified, reason: error.localizedDescription)
            return
        }

        // The confirmation upstream is a whole download old. A draft started
        // since then never got asked, and this is the last moment where
        // saying no still costs nothing.
        if !draftAlreadyAnswered, !confirmRestartOverOpenDraft(release) {
            status = "Update cancelled."
            return
        }

        // Start the relauncher before touching anything. It has to come from
        // the bundle we're running — the one LaunchServices knows and that
        // carries no quarantine. Once the swap lands, the only copy on disk is
        // the update's, which is quarantined like every file a sandboxed
        // process writes and therefore cannot be launched at all.
        //
        // So this failing means the update would install and then be
        // unopenable: better to leave the working app alone and hand over the
        // verified copy instead.
        do {
            try await UpdateInstaller.startRelauncher(appPath: runningApp)
        } catch {
            revealForManualInstall(
                verified,
                reason: "Couldn't start the updater (\(error.localizedDescription)).")
            return
        }

        status = "Installing MishMail \(release.version)…"
        do {
            try UpdateInstaller.withAccess(to: grant) {
                try UpdateInstaller.swap(newApp: verified.appURL, onto: runningApp)
            }
        } catch {
            revealForManualInstall(
                verified,
                reason: "Couldn't install the update (\(error.localizedDescription)).")
            return
        }

        // Past this point the new bundle is already in place and there is no
        // going back: a failure must never read as "nothing happened".
        status = "Restarting MishMail \(release.version)…"
        // Close the database before a second instance opens it. The pool is
        // WAL and multi-process safe, but the quit-path checkpoint shouldn't
        // race a fresh launch's first writes. Re-entrant, so the terminate
        // below awaits this same shutdown rather than redoing it.
        await prepareForQuit?()
        // Backstop, armed *before* terminate and on a background queue, both
        // on purpose. `terminate` can block this task in a nested AppKit
        // event loop (a `.terminateLater` reply scheduled on the main actor
        // can never run while this call is still on the stack), and a
        // main-actor backstop would be stuck in that same queue. Everything
        // is already flushed, so if quitting stalls, staying open only
        // misleads the user — and the relauncher's wait is bounded.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { exit(0) }
        // The relauncher is already running and watching this process; quitting
        // is the signal for it to unquarantine the new bundle and reopen it.
        NSApp.terminate(nil)
    }

    /// Fallback when the app can't install for itself: hand the user the
    /// verified bundle the way the old flow did. They double-click it out of
    /// a temp directory from here, so Gatekeeper's checks are the OS's job
    /// again and the quarantine tag belongs back on it.
    private func revealForManualInstall(_ verified: VerifyResult, reason: String) {
        Self.markQuarantined(verified.appURL)
        status = "\(reason) Drag the revealed MishMail into Applications to install it."
        NSWorkspace.shared.activateFileViewerSelecting([verified.appURL])
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
        case versionMismatch(expected: String, found: String?)
        case teamMismatch(expected: String, found: String?)
        case adHocDowngrade
        case notDeveloperID
        case notNotarized

        var errorDescription: String? {
            switch self {
            case .badHTTP(let code): return "download failed (HTTP \(code))"
            case .noAppInArchive: return "release archive contained no MishMail.app"
            case .invalidSignature(let s): return "code signature invalid (OSStatus \(s))"
            case .unzipFailed(let c): return "unzip failed (exit \(c))"
            case .checksumMismatch: return "SHA-256 did not match the published checksum"
            case .checksumMissingForAsset: return "checksum file did not list this zip"
            case .versionMismatch(let exp, let found):
                return "release \(exp) contains MishMail \(found ?? "of unknown version")"
            case .teamMismatch(let exp, let found):
                return "Team ID mismatch (running \(exp), update \(found ?? "ad-hoc"))"
            case .adHocDowngrade: return "refusing ad-hoc update while running a team-signed build"
            case .notDeveloperID: return "update is not Developer ID signed"
            case .notNotarized: return "update is not notarized"
            }
        }
    }

    /// Full install pipeline: download zip → optional SHA-256 → extract →
    /// version pinning → signature + Team ID + notarization policy →
    /// verified app URL.
    nonisolated static func downloadAndVerifyApp(
        from zipURL: URL,
        checksumURL: URL?,
        expectedVersion: String,
        runningAppURL: URL
    ) async throws -> VerifyResult {
        let (tempFile, resp) = try await URLSession.shared.download(from: zipURL)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw UpdateError.badHTTP(code) }

        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("MishMailUpdate-\(UUID().uuidString)", isDirectory: true)
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
        // Signatures prove identity, not freshness. Every past release is
        // public and carries the same Team ID, so whoever controls the GitHub
        // account — with no signing key at all — could re-publish an old,
        // vulnerable build under a higher tag and roll the app backwards past
        // every other check here. Pin the bundle's own version to the tag we
        // decided was newer; `make release` derives one from the other. The
        // two checks close the gap together: Info.plist is sealed by the code
        // directory, so editing the version to match breaks the signature —
        // which is also why this reads the plist only after that passes.
        let shipped = bundleVersion(of: appURL)
        guard shipped == expectedVersion else {
            throw UpdateError.versionMismatch(expected: expectedVersion, found: shipped)
        }
        let trust = try evaluateTrust(updateApp: appURL, runningApp: runningAppURL,
                                      officialRelease: checksumVerified)
        // Deliberately not quarantined here: an in-place install has already
        // cleared stronger checks than Gatekeeper would apply. Only the
        // manual-install fallback tags it (see `revealForManualInstall`).
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

    /// `CFBundleShortVersionString` of a bundle on disk — the same string
    /// `currentVersion` reads for the running app, so the two compare.
    nonisolated static func bundleVersion(of appURL: URL) -> String? {
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleShortVersionString"] as? String
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
            if url.lastPathComponent == "MishMail.app" { return url }
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
    /// - Source/ad-hoc installs may upgrade only to a notarized Developer ID
    ///   build; an ad-hoc signature has no identity and is not a trust anchor.
    /// - Apple Development builds retain Team ID continuity.
    nonisolated static func evaluateTrust(updateApp: URL, runningApp: URL,
                                          officialRelease: Bool) throws -> TrustOutcome {
        let runningTeam = teamIdentifier(of: runningApp)
        let updateTeam = teamIdentifier(of: updateApp)
        let notarized = isNotarized(updateApp)
        let developerID = isDeveloperID(updateApp)
        // Reserved for callers that want a stricter future checksum policy;
        // identity and notarization rules below apply to every executable.
        _ = officialRelease

        if let runningTeam {
            guard let updateTeam else { throw UpdateError.adHocDowngrade }
            guard updateTeam == runningTeam else {
                throw UpdateError.teamMismatch(expected: runningTeam, found: updateTeam)
            }
        } else {
            // An ad-hoc signature proves only that the archive was internally
            // consistent; anybody can create one. A source/ad-hoc installation
            // may therefore update only to a notarized Developer ID build.
            guard developerID else { throw UpdateError.notDeveloperID }
        }

        if developerID {
            guard notarized else { throw UpdateError.notNotarized }
        }

        return TrustOutcome(teamID: updateTeam, notarized: notarized)
    }

    /// Same quarantine tagging the attachment path uses.
    nonisolated static func markQuarantined(_ url: URL) {
        let stamp = String(format: "%08x", UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970)))
        let value = "0001;\(stamp);MishMail;\(UUID().uuidString)"
        value.withCString { cstr in
            _ = setxattr(url.path, "com.apple.quarantine", cstr, strlen(cstr), 0, 0)
        }
    }
}
