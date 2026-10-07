import Foundation

/// Decisions for one replay pass over the queued thread edits
/// (`PendingThreadOp`). Pure; `MailStore.flushPendingThreadOps` owns the loop.
///
/// The queue holds rows of every account in one `createdAt` order. A failure
/// that belongs to one account (sign-in rejected, quota penalty) must stop
/// that account only; the rows of the other accounts still replay.
enum ThreadOpReplay {
    enum Disposition: Equatable {
        /// No network: no account can replay. Rows stay.
        case stopPass
        /// The row stays; no other row of this account is tried in this pass.
        case skipAccount(reauthorize: Bool)
        /// The row stays and replays next pass; later rows are still tried.
        case keepRow
        /// Delete the row. `revert` re-derives the thread from its message
        /// rows (Gmail's state); `report` shows the error.
        case dropRow(revert: Bool, report: Bool)
    }

    static func replayDisposition(error: Error, accountIsKnown: Bool,
                                  createdAt: Date, now: Date = Date()) -> Disposition {
        // A removed account has no token and no thread rows: the edit can
        // never be sent, and there is nothing to revert or to tell the user.
        guard accountIsKnown else { return .dropRow(revert: false, report: false) }
        if OfflinePolicy.shouldDefer(error) { return .stopPass }
        if AccountLifecycle.isReauthRequired(error) { return .skipAccount(reauthorize: true) }
        if let failure = ThreadEditRetryPolicy.serverFailure(error),
           !ThreadEditRetryPolicy.isExpired(createdAt: createdAt, now: now) {
            switch failure {
            case .rateLimited: return .skipAccount(reauthorize: false)
            case .serverError: return .keepRow
            }
        }
        // Gone or rejected: the next sync shows Gmail's truth.
        return .dropRow(revert: true, report: !SendThreading.isNotFound(error))
    }

    /// Per-pass state: which accounts are out for the rest of the pass.
    struct Pass {
        private var skipped: Set<String> = []
        private var serverErrors: [String: Int] = [:]

        func skips(_ accountId: String) -> Bool {
            skipped.contains(accountId)
        }

        mutating func skip(_ accountId: String) {
            skipped.insert(accountId)
        }

        /// Count a `.keepRow` failure. An account that keeps failing is
        /// skipped, so an outage does not cost one call per queued row.
        mutating func recordServerError(_ accountId: String) {
            let count = (serverErrors[accountId] ?? 0) + 1
            serverErrors[accountId] = count
            if ThreadEditRetryPolicy.stopsReplay(after: .serverError, failuresSoFar: count) {
                skipped.insert(accountId)
            }
        }
    }
}
