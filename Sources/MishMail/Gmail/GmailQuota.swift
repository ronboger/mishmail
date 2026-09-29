import Foundation

/// Token bucket for Gmail's per-user quota: 250 units per second, enforced
/// as a moving average.
///
/// A history catch-up that fires four 50-message batches back to back spends
/// 1000 units in about two seconds. Gmail answers the one that crosses the
/// line with 403 `userRateLimitExceeded` and drops the HTTP/3 connection,
/// which fails every other in-flight get too. The engine then refuses to
/// advance the history id, and the next pass replays the same range and hits
/// the same wall — forever. Pacing the spend below the average, in smaller
/// batches, keeps a pass under the ceiling.
///
/// Pure value type so the pacing math is unit-tested; `GmailClient` owns one
/// per account (the limit is per user) and sleeps for the delay it returns.
struct GmailQuotaBucket {
    /// `messages.get` costs 5 units regardless of format.
    static let messageGetUnits = 5
    /// Keep a half-second of burst capacity. Gmail's 250 units/s limit is a
    /// moving average, so a 125-unit burst leaves room for refill while the
    /// next request is in flight.
    static let defaultCapacity = 125
    /// Below Gmail's 250/s so the moving average never touches the ceiling.
    static let defaultRefillPerSecond = 200

    let capacity: Int
    let refillPerSecond: Int
    /// Units still spendable at `lastRefill`. May go negative: a spend that
    /// had to wait is charged at the time it was told to wait until.
    private var tokens: Double
    private var lastRefill: Date?
    private var blockedUntil: Date?

    init(capacity: Int = defaultCapacity, refillPerSecond: Int = defaultRefillPerSecond) {
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
        self.tokens = Double(capacity)
        self.blockedUntil = nil
    }

    static func units(forMessageGets count: Int) -> Int {
        count * messageGetUnits
    }

    /// Longest penalty the bucket keeps: the longest wait honored from a
    /// Gmail body plus the retry jitter. A clock jump or a bad stamp can then
    /// never park the account for longer.
    static let maxPenalty: TimeInterval = GmailRateLimit.maxWait + 1

    /// Seconds left in the current penalty, or zero when none is active.
    /// Clears an expired penalty and clamps one that lies further ahead than
    /// `maxPenalty` (the clock jumped back, or a bad stamp got through).
    mutating func penaltyRemaining(now: Date) -> TimeInterval {
        guard let until = blockedUntil else { return 0 }
        if until <= now {
            blockedUntil = nil
            return 0
        }
        let limit = now.addingTimeInterval(Self.maxPenalty)
        if until > limit {
            blockedUntil = limit
            if let last = lastRefill, last > limit { lastRefill = limit }
        }
        return blockedUntil!.timeIntervalSince(now)
    }

    /// Reserves `units` and returns how long the caller must wait before
    /// sending. Zero when the bucket has room now.
    ///
    /// Under a penalty the spend is reserved at the moment the penalty ends,
    /// so callers parked behind it are released one refill apart instead of
    /// all together. A single delay never exceeds `GmailRateLimit.maxWait`.
    mutating func delayBeforeSpending(units: Int, now: Date) -> TimeInterval {
        let penalty = penaltyRemaining(now: now)
        let start = now.addingTimeInterval(penalty)
        if let last = lastRefill {
            let elapsed = max(0, start.timeIntervalSince(last))
            tokens = min(Double(capacity), tokens + elapsed * Double(refillPerSecond))
            // A clock that jumped back must not stretch the next refill.
            lastRefill = min(max(last, start), now.addingTimeInterval(Self.maxPenalty))
        } else {
            lastRefill = start
        }
        tokens -= Double(units)
        // Deficit refills at `refillPerSecond`; the caller sleeps that long.
        let deficit = tokens < 0 ? -tokens / Double(refillPerSecond) : 0
        return min(penalty + deficit, GmailRateLimit.maxWait)
    }

    /// Blocks every caller until Gmail's penalty window or the local retry
    /// backoff expires. The client owns this bucket, so unrelated requests for
    /// the same account observe the same penalty. Gmail refused the last
    /// spend, so the bucket restarts empty when the penalty ends.
    mutating func block(until: Date) {
        if self.blockedUntil == nil || until > self.blockedUntil! {
            self.blockedUntil = until
        }
        tokens = min(tokens, 0)
        if lastRefill == nil || until > lastRefill! {
            lastRefill = until
        }
    }
}

/// Gmail's quota error names the moment the window reopens:
/// `"User-rate limit exceeded.  Retry after 2026-09-16T03:57:19.386Z"`.
enum GmailRateLimit {
    /// Longest wait honored from the body. A skewed clock or a far-future
    /// timestamp must not park the sync for minutes.
    static let maxWait: TimeInterval = 30

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let whole = ISO8601DateFormatter()

    /// Seconds to wait before retrying, from the "Retry after <ISO 8601>"
    /// phrase in the error body. Nil when the body names no time.
    static func retryAfter(body: String, now: Date = Date()) -> TimeInterval? {
        guard let range = body.range(of: #"Retry after ([0-9T:.\-]+Z)"#, options: .regularExpression) else {
            return nil
        }
        let stamp = String(body[range]).replacingOccurrences(of: "Retry after ", with: "")
        guard let date = fractional.date(from: stamp) ?? whole.date(from: stamp) else { return nil }
        return min(max(0, date.timeIntervalSince(now)), maxWait)
    }
}

/// Delay before retrying a failed `messages.get`.
///
/// A dropped connection is back within a fraction of a second. A rate limit
/// is not: Gmail keeps answering 403 until its window reopens, so those
/// retries wait for the time Gmail names, or whole seconds when it names
/// none. Sub-second retries only burn the attempts and the whole pass.
enum GmailRetryBackoff {
    static func delay(attempt: Int, kind: MessageFetchFailureKind,
                      retryAfter: TimeInterval? = nil,
                      jitter: TimeInterval = 0) -> TimeInterval {
        let base: TimeInterval
        switch kind {
        case .rateLimited:
            let scheduled = 2.0 * Double(1 << attempt)   // 2s, 4s, 8s
            base = max(scheduled, retryAfter ?? 0)
        default:
            base = 0.2 * Double(1 << attempt)   // 0.2s, 0.4s
        }
        return base + max(0, jitter)
    }

    /// Small decorrelation jitter prevents several callers released by the
    /// same quota penalty from forming another synchronized burst.
    static func jitter() -> TimeInterval {
        Double.random(in: 0...0.25)
    }
}

/// Cuts a history catch-up into slices the engine can commit one at a time.
///
/// History used to be fetched as one unit, and the new history id recorded
/// only when every message in it had landed. A rate limit anywhere in the
/// run recorded nothing, and the next pass replayed the same range — for
/// days, growing as it went. Each slice ends on a record id that is a valid
/// `startHistoryId`, so the engine saves it after the slice's messages are
/// flushed and a later failure loses one slice, not the pass.
enum HistorySlicer {
    struct Record: Equatable {
        let id: String
        /// Messages the record adds (full fetch).
        let addedIds: [String]
        /// Messages whose labels the record changes (fetch when not cached).
        let labelChangedIds: [String]
        /// Messages the record deletes. They cost no API call, but each one is
        /// a bound SQL variable and a row write, so they count toward the
        /// budget: one slice must not carry an unbounded delete.
        var deletedIds: [String] = []
        /// Position in the caller's array, so the engine can map back.
        var index: Int = 0

        var messageCount: Int { addedIds.count + labelChangedIds.count + deletedIds.count }
    }

    struct Slice: Equatable {
        let records: [Record]
        var lastRecordId: String { records.last?.id ?? "" }
    }

    /// Groups records in order until a slice holds `maxMessages` or more.
    /// A record is never split, so one oversized record forms its own slice.
    static func slices(_ records: [Record], maxMessages: Int) -> [Slice] {
        var result: [Slice] = []
        var current: [Record] = []
        var count = 0
        for record in records {
            if !current.isEmpty, count + record.messageCount > maxMessages {
                result.append(Slice(records: current))
                current = []
                count = 0
            }
            current.append(record)
            count += record.messageCount
        }
        if !current.isEmpty { result.append(Slice(records: current)) }
        return result
    }
}
