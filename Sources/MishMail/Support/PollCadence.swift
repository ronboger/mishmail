import Foundation

/// How often the background sync timer fires.
///
/// A fixed 60-second poll paid the same cost whether the user was reading mail
/// or had not touched the app in an hour. Every tick wakes the process and
/// opens HTTPS connections to Gmail for each account.
///
/// The backoff is deliberately mild. This is a mail client: while it is in the
/// background, polling is the only thing that produces new-mail notifications,
/// so stretching the interval trades notification latency for battery. Three
/// minutes keeps that trade honest; Low Power Mode, where the user has
/// explicitly asked the system to conserve, goes further.
///
/// Note this is *not* keyed on running from battery. On a laptop that is the
/// normal case, and delaying mail whenever the charger is out would be a
/// product regression dressed up as an optimization.
///
/// The latency this could add is bought back at the moment it matters:
/// `MailStore` syncs immediately when the app becomes frontmost, so the list
/// the user is actually looking at is never stale for a full interval.
enum PollCadence {
    /// App is frontmost — the user is looking at the mailbox.
    static let active: TimeInterval = 60
    /// App is running but not frontmost. Notifications still arrive; they can
    /// be up to this late.
    static let background: TimeInterval = 180
    /// User asked the system to conserve power.
    static let lowPower: TimeInterval = 300

    static func interval(appActive: Bool, lowPowerMode: Bool) -> TimeInterval {
        if lowPowerMode { return lowPower }
        return appActive ? active : background
    }
}
