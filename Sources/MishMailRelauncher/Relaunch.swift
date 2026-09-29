import Foundation
import Security

/// The contract between MishMail and its embedded relauncher, compiled into
/// both targets so the two sides can never disagree about paths or format.
///
/// Nothing here travels through argv, because nothing can: macOS strips
/// `NSWorkspace.OpenConfiguration.arguments` when the launching process is
/// sandboxed, silently — the helper starts healthy, argument-less, and
/// useless. Instead the app writes a *plan file* at a path both sides can compute
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

    /// Plan nonces become filenames, so only UUID strings are accepted.
    static func isValidNonce(_ nonce: String) -> Bool {
        UUID(uuidString: nonce) != nil
    }

    /// The helper is nested inside the installed MishMail bundle. Walk from
    /// the helper bundle's parent so this returns the enclosing app, not the
    /// helper's own `.app` bundle.
    static func enclosingAppBundle(forHelperBundle helperBundleURL: URL) -> URL? {
        var candidate = helperBundleURL.standardizedFileURL.deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.pathExtension.lowercased() == "app" {
                return candidate.resolvingSymlinksInPath().standardizedFileURL
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    /// Updates replace MishMail.app in place. Resolve both sides before
    /// comparing so a plan cannot redirect the unsandboxed helper through a
    /// symlink to another application.
    static func resolvedTargetAppURL(
        appPath: String,
        helperBundleURL: URL
    ) -> URL? {
        guard let enclosing = enclosingAppBundle(forHelperBundle: helperBundleURL) else {
            return nil
        }
        let target = URL(fileURLWithPath: appPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        return target.path == enclosing.path ? target : nil
    }

    /// Team ID of the running helper, read from the kernel's view of this
    /// process. Reading the helper's file instead would be circular: after
    /// the swap, the helper's path holds the NEW bundle's copy, so the update
    /// would supply its own trust anchor. Nil for ad-hoc (Debug) helpers.
    static func runningTeamIdentifier() -> String? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var info: CFDictionary?
        // A SecCode is accepted wherever a SecStaticCode is (documented).
        let asStatic = unsafeBitCast(me, to: SecStaticCode.self)
        guard SecCodeCopySigningInformation(
            asStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func teamRequirementString(for teamID: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// The swapped-in bundle is checked immediately before quarantine is
    /// removed. With a team, it must chain to Apple and carry that team. An
    /// ad-hoc (Debug) helper has no certificate identity, so only signature
    /// validity is required there.
    static func hasValidTargetSignature(at targetURL: URL, teamID: String?) -> Bool {
        let flags = SecCSFlags(
            rawValue: kSecCSCheckNestedCode | kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        var targetCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(targetURL as CFURL, [], &targetCode) == errSecSuccess,
              let targetCode else {
            return false
        }
        guard let teamID else {
            return SecStaticCodeCheckValidity(targetCode, flags, nil) == errSecSuccess
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            teamRequirementString(for: teamID) as CFString, [], &requirement) == errSecSuccess,
            let requirement else {
            return false
        }
        return SecStaticCodeCheckValidity(targetCode, flags, requirement) == errSecSuccess
    }

    /// The helper's route to the app's container tmp: unsandboxed, `home` is
    /// the real home directory, and the container location is fixed by macOS.
    static func containerTemp(home: URL) -> URL {
        home.appendingPathComponent("Library/Containers/\(bundleID)/Data/tmp",
                                    isDirectory: true)
    }
}
