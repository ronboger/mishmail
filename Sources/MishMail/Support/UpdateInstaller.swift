import Foundation
import AppKit

/// Puts a verified update in place. `UpdateChecker` decides *whether* a
/// download is trustworthy; this decides where it goes.
///
/// The app is sandboxed with `files.user-selected.read-write` and nothing else
/// file-related, so it cannot write its own install directory unaided. The
/// user grants that one folder through an open panel, the grant persists as an
/// app-scoped security bookmark (`files.bookmarks.app-scope`), and every later
/// update installs on a single click.
enum UpdateInstaller {
    static let bookmarkKey = "updates.installDirBookmark"

    enum InstallError: LocalizedError, Equatable {
        case grantDeclined
        case wrongFolder(chosen: String, expected: String)
        case relauncherMissing
        case relaunchFailed(String)

        var errorDescription: String? {
            switch self {
            case .grantDeclined:
                return "MishMail needs permission to replace itself before it can install the update."
            case .wrongFolder(let chosen, let expected):
                return "Chose “\(chosen)”, but MishMail is installed in “\(expected)”."
            case .relauncherMissing:
                return "the update has no embedded relauncher"
            case .relaunchFailed(let why):
                // Read inside a sentence the caller builds around it ("couldn't
                // restart itself (…)"), so this is the bare reason, not a
                // phrase that would nest a second set of parentheses.
                return why
            }
        }
    }

    // MARK: - Where the app lives

    /// The folder holding the running app — `/Applications` after a
    /// `make install`, but resolved rather than assumed so an app the user
    /// moved still updates itself where it actually is.
    nonisolated static func installDirectory(for app: URL) -> URL {
        app.deletingLastPathComponent()
    }

    /// True when the running app is on a read-only App Translocation mount —
    /// what macOS does with a quarantined app launched straight from where it
    /// was downloaded instead of being moved first. There is no real install
    /// directory to swap into until the user puts it somewhere permanent.
    nonisolated static func isTranslocated(_ app: URL) -> Bool {
        app.resolvingSymlinksInPath().path.contains("/AppTranslocation/")
    }

    /// A stored grant is reused only for the folder the running app is in.
    /// Anything else means the app moved since the last update, and the stale
    /// grant would install over a bundle nobody is running.
    nonisolated static func grantMatches(_ granted: URL, installDirectory: URL) -> Bool {
        granted.resolvingSymlinksInPath().standardizedFileURL.path
            == installDirectory.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - The grant

    /// Resolve a persisted grant, or `nil` when there is none, it no longer
    /// resolves, or it points somewhere other than the running app's folder.
    /// A bookmark that fails any of those is dropped so the next attempt
    /// re-prompts instead of failing the same way forever.
    nonisolated static func resolveGrant(installDirectory: URL,
                                         defaults: UserDefaults = .standard) -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [.withSecurityScope],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale),
              grantMatches(url, installDirectory: installDirectory) else {
            defaults.removeObject(forKey: bookmarkKey)
            return nil
        }
        // A stale bookmark still resolved, so the grant is live — refresh it
        // inside its own scope rather than throwing the access away.
        if stale {
            withAccess(to: url) { try? persistGrant(url, defaults: defaults) }
        }
        return url
    }

    /// Ask for the folder once. The panel opens on the install directory with
    /// nothing selected, so confirming without navigating grants exactly the
    /// folder we need.
    @MainActor
    static func requestGrant(installDirectory: URL,
                             defaults: UserDefaults = .standard) throws -> URL {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = installDirectory
        panel.prompt = "Grant Access"
        panel.message = "MishMail is sandboxed and needs one-time permission to replace "
            + "itself in “\(installDirectory.lastPathComponent)”. Later updates install "
            + "with a single click."
        guard panel.runModal() == .OK, let chosen = panel.url else {
            throw InstallError.grantDeclined
        }
        guard grantMatches(chosen, installDirectory: installDirectory) else {
            throw InstallError.wrongFolder(chosen: chosen.lastPathComponent,
                                           expected: installDirectory.lastPathComponent)
        }
        try? persistGrant(chosen, defaults: defaults)
        return chosen
    }

    /// Persisting fails only if the app-scope bookmark entitlement is missing;
    /// the install still works this once, it just re-prompts next time.
    nonisolated static func persistGrant(_ url: URL,
                                         defaults: UserDefaults = .standard) throws {
        let data = try url.bookmarkData(options: [.withSecurityScope],
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        defaults.set(data, forKey: bookmarkKey)
    }

    /// Run `body` with the granted folder's security scope held open. A URL
    /// that came straight from the panel is already accessible, so a `false`
    /// return is not an error — only an unbalanced `stop` would be.
    @discardableResult
    nonisolated static func withAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        let opened = url.startAccessingSecurityScopedResource()
        defer { if opened { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    // MARK: - The swap

    /// Replace the installed bundle with the verified one.
    ///
    /// `replaceItemAt` stages the new bundle beside the old one and swaps, so
    /// an interrupted install (crash, full disk) leaves the running app
    /// untouched rather than half-written. Deleting the bundle a running
    /// process was launched from is fine on macOS — open file references
    /// survive — but resources loaded lazily *after* this point come from the
    /// new bundle, which is why the caller relaunches immediately.
    nonisolated static func swap(newApp: URL, onto installedApp: URL) throws {
        clearQuarantine(newApp)
        _ = try FileManager.default.replaceItemAt(installedApp, withItemAt: newApp)
    }

    /// The installed update is deliberately *not* quarantined: it has already
    /// passed SHA-256, a full nested signature check, and Team ID continuity
    /// with the running app — stronger than Gatekeeper's check on an Apple
    /// Development build, where the tag buys nothing but a warning on every
    /// update. Nothing in the download path sets the attribute; this is
    /// belt-and-braces so the intent is explicit at the swap.
    nonisolated static func clearQuarantine(_ url: URL) {
        _ = removexattr(url.path, "com.apple.quarantine", 0)
    }

    // MARK: - Relaunch

    /// The relauncher embedded in an app bundle. Resolved against the bundle
    /// being *installed* rather than the running one — after the swap that
    /// path holds the new copy, and its relauncher is the one that exists on
    /// disk.
    nonisolated static func relauncherURL(inside app: URL) -> URL {
        app.appendingPathComponent("Contents/Library/MishMailRelauncher.app")
    }

    /// Start the embedded relauncher, then quit so it can do its job.
    ///
    /// MishMail can't restart itself. Asking LaunchServices for a second
    /// instance of the bundle we're running from fails with -10810, and the
    /// sandbox blocks spawning a shell to do it instead — both were tried, and
    /// both failed on real hardware. The relauncher is a separate bundle id,
    /// so launching it is an ordinary "open another app" that the sandbox
    /// permits, and it waits for this process to disappear before reopening
    /// the new copy.
    ///
    /// Awaiting the launch matters: it means the helper is running *before* we
    /// terminate, so nothing is lost in the gap.
    @MainActor
    static func relaunch(_ app: URL) async throws {
        let helper = relauncherURL(inside: app)
        guard FileManager.default.fileExists(atPath: helper.path) else {
            throw InstallError.relauncherMissing
        }
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = [String(ProcessInfo.processInfo.processIdentifier), app.path]
        // It has no UI; pulling focus to it would only flicker.
        config.activates = false
        config.createsNewApplicationInstance = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: helper, configuration: config)
        } catch {
            throw InstallError.relaunchFailed(error.localizedDescription)
        }
        NSApp.terminate(nil)
    }
}
