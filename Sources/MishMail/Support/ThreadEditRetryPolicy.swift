import Foundation

/// What to do with a thread edit (`threads.modify` / `threads.trash`) that
/// Gmail answered with a quota or server error. Pure; `MailStore` owns the
/// queue (`PendingThreadOp`).
///
/// These answers mean "not now", not "no": Gmail is reachable, so the app is
/// not offline, but the edit must not be reverted. It is kept in the same
/// queue as an offline edit and replayed ahead of the next sync. Label edits
/// and trash are idempotent, so a replay of an edit that did land (a 5xx can
/// hide a success) is harmless.
enum ThreadEditRetryPolicy {
    enum ServerFailure: Equatable {
        /// 429, or 403 with a `usageLimits` reason. Per user: every further
        /// call for the account fails until the penalty ends.
        case rateLimited
        /// 5xx. Can be one request or the whole backend.
        case serverError
    }

    static func serverFailure(_ error: Error) -> ServerFailure? {
        guard case GmailError.http(let code, let body) = error else { return nil }
        if code == 429 { return .rateLimited }
        if code == 403, MessageFetchFailureKind.isRateLimitBody(body) { return .rateLimited }
        if (500...599).contains(code) { return .serverError }
        return nil
    }

    /// True when the edit should stay queued instead of being reverted.
    static func shouldRequeue(_ error: Error) -> Bool {
        serverFailure(error) != nil
    }

    /// How long a queued edit can keep failing with a server error. Past
    /// this the row is dropped and the thread shows Gmail's state again: an
    /// edit that old is more likely to overwrite a newer change made on
    /// another device than to be what the user still wants.
    static let maxQueuedAge: TimeInterval = 24 * 60 * 60

    static func isExpired(createdAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(createdAt) > maxQueuedAge
    }

    /// Server errors one replay pass accepts before it stops. One bad row
    /// must not block the rows behind it, but an outage must not cost one
    /// failed call per queued row on every pass.
    static let maxServerFailuresPerPass = 3

    /// `failuresSoFar` counts this failure.
    static func stopsReplay(after failure: ServerFailure, failuresSoFar: Int) -> Bool {
        switch failure {
        case .rateLimited: return true
        case .serverError: return failuresSoFar >= maxServerFailuresPerPass
        }
    }
}
