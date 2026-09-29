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
    static let defaultCapacity = 250
    /// Below Gmail's 250/s so the moving average never touches the ceiling.
    static let defaultRefillPerSecond = 200

    let capacity: Int
    let refillPerSecond: Int
    /// Units still spendable at `lastRefill`. May go negative: a spend that
    /// had to wait is charged at the time it was told to wait until.
    private var tokens: Double
    private var lastRefill: Date?

    init(capacity: Int = defaultCapacity, refillPerSecond: Int = defaultRefillPerSecond) {
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
        self.tokens = Double(capacity)
    }

    static func units(forMessageGets count: Int) -> Int {
        count * messageGetUnits
    }

    /// Reserves `units` and returns how long the caller must wait before
    /// sending. Zero when the bucket has room now.
    mutating func delayBeforeSpending(units: Int, now: Date) -> TimeInterval {
        if let last = lastRefill {
            let elapsed = max(0, now.timeIntervalSince(last))
            tokens = min(Double(capacity), tokens + elapsed * Double(refillPerSecond))
        }
        lastRefill = now
        tokens -= Double(units)
        guard tokens < 0 else { return 0 }
        // Deficit refills at `refillPerSecond`; the caller sleeps that long.
        return -tokens / Double(refillPerSecond)
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
                      retryAfter: TimeInterval? = nil) -> TimeInterval {
        switch kind {
        case .rateLimited:
            let scheduled = 2.0 * Double(1 << attempt)   // 2s, 4s, 8s
            return max(scheduled, retryAfter ?? 0)
        default:
            return 0.2 * Double(1 << attempt)   // 0.2s, 0.4s
        }
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
        /// Position in the caller's array, so the engine can map back.
        var index: Int = 0

        var messageCount: Int { addedIds.count + labelChangedIds.count }
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
