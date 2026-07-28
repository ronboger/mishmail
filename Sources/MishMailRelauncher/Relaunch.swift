import Foundation

/// The contract between MishMail and its embedded relauncher, compiled into
/// both targets so the two sides can never disagree about paths or format.
///
/// Nothing here travels through argv, because nothing can: macOS strips
/// `NSWorkspace.OpenConfiguration.arguments` when the launching process is
/// sandboxed, silently — the helper starts healthy, argument-less, and
/// useless (the 0.4.9→0.4.10 breadcrumbs: `start: args=[]`, `exit 64`,
/// 3ms apart; every earlier update's restart died the same invisible way).
/// Instead the app writes a *plan file* at a path both sides can compute
/// independently: the app because the container tmp IS its temporary
/// directory, the unsandboxed helper because container paths follow from
/// `$HOME` and the fixed bundle id.
enum Relaunch {
    struct Plan: Codable {
        /// The MishMail process to wait out.
        let pid: Int32
        /// The installed bundle to unquarantine and reopen.
        let appPath: String
        /// Names the ready marker, so the app's handshake wait can only be
        /// satisfied by the helper it just launched — not by a marker some
        /// earlier attempt left behind.
        let nonce: String
    }

    static let bundleID = "dev.ronboger.MishMail"
    static let planName = "relauncher-plan.json"

    /// The sandboxed app's `FileManager.temporaryDirectory` and the helper's
    /// `containerTemp(home:)` resolve to this same directory.
    static func planURL(inTemp temp: URL) -> URL {
        temp.appendingPathComponent(planName)
    }

    /// Written by the helper as its first act; awaited by the app before it
    /// swaps anything.
    static func markerURL(inTemp temp: URL, nonce: String) -> URL {
        temp.appendingPathComponent("relauncher-ready-\(nonce)")
    }

    /// The helper's route to the app's container tmp: unsandboxed, `home` is
    /// the real home directory, and the container location is fixed by macOS.
    static func containerTemp(home: URL) -> URL {
        home.appendingPathComponent("Library/Containers/\(bundleID)/Data/tmp",
                                    isDirectory: true)
    }
}
