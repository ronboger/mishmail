import Foundation

/// Removes `com.apple.quarantine` from a bundle, item by item.
///
/// This lives in the relauncher, not the app, because the sandbox forbids it
/// anywhere else: every file a sandboxed process writes is force-quarantined
/// by the kernel no matter how it is written, and `removexattr` on that
/// attribute fails with EPERM from inside the sandbox — silently, since the
/// call compiles and simply returns -1. The relauncher is signed *without*
/// the sandbox entitlement precisely so this call is permitted.
///
/// Gatekeeper refuses to launch a quarantined un-notarized bundle outright
/// (LaunchServices -10810), so a freshly swapped-in update is unlaunchable
/// until every one of its items — including the nested relauncher bundle —
/// loses the attribute.
enum Quarantine {
    /// Strip the root and everything under it, returning how many items
    /// actually had the attribute — the caller logs it, and 0 on a bundle
    /// that should be freshly quarantined is the tell that something ran at
    /// the wrong moment. Untagged items are a no-op; symlinks are cleared
    /// themselves (`XATTR_NOFOLLOW`) rather than whatever they point at —
    /// app bundles are full of them.
    @discardableResult
    static func strip(from root: URL) -> Int {
        var count = stripItem(root) ? 1 : 0
        guard let items = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else { return count }
        for case let item as URL in items where stripItem(item) {
            count += 1
        }
        return count
    }

    /// True when the attribute existed and was removed.
    @discardableResult
    static func stripItem(_ url: URL) -> Bool {
        removexattr(url.path, "com.apple.quarantine", XATTR_NOFOLLOW) == 0
    }
}
