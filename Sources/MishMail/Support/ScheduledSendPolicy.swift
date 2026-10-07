import Foundation

/// What the due-sweep does with a scheduled send that did not go out.
/// Pure so the rules are unit-tested; `MailStore.fireDueScheduledSends`
/// owns the rows.
///
/// Two outcomes are unacceptable: a message sent twice and a message lost.
/// So a row leaves the schedule only when Gmail has the message, or when
/// the message is handed back to a compose card that is free to hold it.
enum ScheduledSendPolicy {
    /// Why a due row is still in the schedule.
    enum Hold: Equatable {
        /// The sending account must be reauthorized first.
        case signIn
        /// Rate limit / server error / unknown outcome: retried on a backoff.
        case retry
        /// Gmail rejected the message, but the compose card is occupied.
        /// Handed back as soon as it is free.
        case rejected

        /// Whether later rows of the same account are skipped this sweep.
        /// A rejection is about one message; the other two are about the
        /// account and would fail the same way for each of its rows.
        var blocksAccount: Bool { self != .rejected }
    }

    struct HoldState: Equatable {
        var hold: Hold
        /// First failure of the current streak (drives `retryGiveUp`).
        var since: Date

        static func next(_ hold: Hold, previous: HoldState?, now: Date) -> HoldState {
            HoldState(hold: hold, since: previous?.since ?? now)
        }
    }

    enum Action: Equatable {
        /// No network: keep every row and end the sweep.
        case stopSweep
        /// Keep the row and move on.
        case hold(Hold)
        /// Delete the row and reopen the message in compose with the error.
        case restoreToCompose
    }

    /// Backoff for the timer while a due row is held. The poll tick and the
    /// reconnect edge also sweep, so this is a ceiling, not the only retry.
    static let heldRetry: TimeInterval = 60
    /// How long a row may keep failing with a retryable error before it is
    /// handed to the user. Without this a 5xx Gmail returns for one specific
    /// message would leave it silently unsent forever.
    static let retryGiveUp: TimeInterval = 15 * 60

    /// `messages.send` threw.
    static func action(afterSendFailure error: Error, composeIsOpen: Bool,
                       failingSince: Date?, now: Date = Date()) -> Action {
        let handBack: Action = composeIsOpen ? .hold(.rejected) : .restoreToCompose
        switch RemoteFailureKind.classify(error) {
        case .offline: return .stopSweep
        case .reauth: return .hold(.signIn)
        case .permanent: return handBack
        case .retryable:
            return gaveUp(failingSince: failingSince, now: now) ? handBack : .hold(.retry)
        }
    }

    /// The "did Gmail already take this Message-ID?" lookup threw. Sending
    /// anyway is how an ambiguous failure becomes a duplicate, so the row
    /// waits until the lookup can answer. `nil` means go ahead and send:
    /// Gmail rejected the lookup itself (it will never answer), or it has
    /// been failing for the whole give-up window.
    static func action(afterSentCheckFailure error: Error,
                       failingSince: Date?, now: Date = Date()) -> Action? {
        switch RemoteFailureKind.classify(error) {
        case .offline: return .stopSweep
        case .reauth: return .hold(.signIn)
        case .permanent: return nil
        case .retryable:
            return gaveUp(failingSince: failingSince, now: now) ? nil : .hold(.retry)
        }
    }

    private static func gaveUp(failingSince: Date?, now: Date) -> Bool {
        guard let failingSince else { return false }
        return now.timeIntervalSince(failingSince) >= retryGiveUp
    }

    /// Delay before the scheduled-send timer fires again; nil with no rows.
    ///
    /// A due row that is held (or due while offline) is waiting on something
    /// other than the clock, so it must not re-arm the timer at the 1s floor
    /// — that is a full MIME build and a Gmail call every second. Rows that
    /// are not held keep their exact time.
    static func timerDelay(rows: [(sendAt: Date, held: Bool)], isOffline: Bool,
                           now: Date = Date()) -> TimeInterval? {
        rows.map { row -> TimeInterval in
            let remaining = row.sendAt.timeIntervalSince(now)
            if remaining > OfflinePolicy.sendRetryFloor { return remaining }
            if row.held { return heldRetry }
            return isOffline ? OfflinePolicy.offlineSendRetry : OfflinePolicy.sendRetryFloor
        }.min()
    }

    /// Holds for rows that still exist.
    static func prune(_ holds: [Int64: HoldState], keeping ids: [Int64]) -> [Int64: HoldState] {
        let live = Set(ids)
        return holds.filter { live.contains($0.key) }
    }

    /// Scheduled-list status for a row whose time has passed; nil while the
    /// row is still waiting on the clock.
    static func waitingStatus(sendAt: Date, hold: Hold?,
                              now: Date = Date()) -> (text: String, systemImage: String)? {
        guard OfflinePolicy.isWaitingForConnection(sendAt: sendAt, now: now) else { return nil }
        switch hold {
        case nil:
            return (OfflinePolicy.waitingForConnectionLabel, "wifi.slash")
        case .signIn:
            return ("Waiting for sign-in", "person.crop.circle.badge.exclamationmark")
        case .retry:
            return ("Gmail is busy — retrying", "arrow.clockwise")
        case .rejected:
            return ("Not sent — edit to fix", "exclamationmark.triangle")
        }
    }
}
