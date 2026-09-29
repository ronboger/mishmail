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

/// `Timer.tolerance` values for the app's repeating and one-shot timers.
///
/// A timer with zero tolerance forces the system to wake the CPU at that
/// exact instant; any slack lets the kernel coalesce the wake with other
/// work already scheduled nearby. Apple's guidance is roughly 10% of the
/// interval. Capped per timer so a long interval never drifts further than
/// its caller can accept.
enum TimerTolerance {
    /// 10% of `interval`, clamped to `0...cap`.
    static func forInterval(_ interval: TimeInterval, cap: TimeInterval) -> TimeInterval {
        guard interval > 0, cap > 0 else { return 0 }
        return min(interval * 0.1, cap)
    }

    /// Poll timer (60 s / 180 s / 300 s): up to 30 s late is invisible for
    /// background sync, and focus changes sync immediately anyway.
    static let pollCap: TimeInterval = 30
    /// Hourly update-check tick: nothing about it is time-sensitive.
    static let updateCheckCap: TimeInterval = 300
    /// Scheduled send: the user picked a time. At most a second late.
    static let scheduledSendCap: TimeInterval = 1
}
