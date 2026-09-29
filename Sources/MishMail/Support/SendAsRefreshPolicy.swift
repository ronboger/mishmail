import Foundation

/// When a post-sync pass may re-fetch an account's Gmail send-as aliases.
///
/// Every successful poll tick used to call `users.settings.sendAs.list` for
/// every account — once a minute per account, forever, for a list that
/// changes only when the user edits aliases in Gmail settings. That was one
/// of the largest steady-state energy costs of an idle, open app (a radio
/// wake plus a TLS round trip per account per minute).
///
/// Launch and sign-in still fetch unconditionally; this gate only covers the
/// opportunistic refresh after a sync. Pure so the thresholds are testable.
enum SendAsRefreshPolicy {
    /// After a successful fetch, the aliases are trusted this long. An alias
    /// added in Gmail's web settings shows up in the From menu within half
    /// an hour (or immediately on relaunch / re-sign-in).
    static let successInterval: TimeInterval = 30 * 60
    /// After a failed fetch (offline, pre-scope 403), wait this long before
    /// retrying. Failures are not stamped as success so an offline launch
    /// recovers its aliases on the first good sync after this back-off,
    /// rather than 30 minutes later.
    static let failureRetryInterval: TimeInterval = 5 * 60

    /// - Parameters:
    ///   - lastSuccess: When a fetch for this account last succeeded.
    ///   - lastAttempt: When a fetch for this account was last tried
    ///     (success or failure).
    static func isDue(lastSuccess: Date?, lastAttempt: Date?, now: Date) -> Bool {
        if let lastSuccess, isWithin(successInterval, since: lastSuccess, now: now) {
            return false
        }
        if let lastAttempt, isWithin(failureRetryInterval, since: lastAttempt, now: now) {
            return false
        }
        return true
    }

    /// A stamp in the future (clock moved backwards) counts as expired, so a
    /// clock change can never suppress refreshes indefinitely.
    private static func isWithin(_ interval: TimeInterval, since stamp: Date,
                                 now: Date) -> Bool {
        let age = now.timeIntervalSince(stamp)
        return age >= 0 && age < interval
    }
}
