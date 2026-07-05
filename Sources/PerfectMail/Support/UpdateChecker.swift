import Foundation
import AppKit

/// Checks GitHub Releases for a newer version of the app. The app is
/// sandboxed, so there is no in-place auto-install: "Update App" downloads
/// the latest release (dmg/zip asset, or the release page if none), and the
/// user replaces the copy in Applications.
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
            let asset = gh.assets.first { $0.name.hasSuffix(".dmg") }
                ?? gh.assets.first { $0.name.hasSuffix(".zip") }
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

    func openUpdate() {
        guard let available else { return }
        NSWorkspace.shared.open(available.assetURL ?? available.htmlURL)
    }
}
