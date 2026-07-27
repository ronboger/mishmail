import Foundation

/// Removes `com.apple.quarantine` from a bundle, item by item.
///
/// This lives in the relauncher, not the app, because the sandbox forbids it
/// anywhere else: every file a sandboxed process writes is force-quarantined
/// by the kernel no matter how it is written, and `removexattr` on that
/// attribute fails with EPERM from inside the sandbox — silently, since the
/// call compiles and simply returns -1. That is how three releases shipped a
/// "clear quarantine" step that never cleared anything (see the 0.4.5
/// addendum in docs/superpowers/specs/2026-07-27-in-place-app-update-design.md).
/// The relauncher is signed *without* the sandbox entitlement precisely so
/// this call is permitted.
///
/// Gatekeeper refuses to launch a quarantined un-notarized bundle outright
/// (LaunchServices -10810), so a freshly swapped-in update is unlaunchable
/// until every one of its items — including the nested relauncher bundle —
/// loses the attribute.
enum Quarantine {
    /// Strip the root and everything under it. Untagged items are a no-op;
    /// symlinks are cleared themselves (`XATTR_NOFOLLOW`) rather than
    /// whatever they point at — app bundles are full of them.
    static func strip(from root: URL) {
        stripItem(root)
        guard let items = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else { return }
        for case let item as URL in items {
            stripItem(item)
        }
    }

    static func stripItem(_ url: URL) {
        _ = removexattr(url.path, "com.apple.quarantine", XATTR_NOFOLLOW)
    }
}
