import Foundation

/// Rate limit for the progress strings shown in the sync control
/// (`MailStore.syncStatus`).
///
/// `SyncEngine.syncNow` and the AI sorter report progress per page / per
/// thread. Each report used to hop to the main actor and assign
/// `syncStatus`, and every assignment republishes the FilterBar (and any
/// other view that reads the status) — dozens of redraws a second during a
/// first sync, most of them for a string nobody can read that fast, and
/// many of them for the exact same string.
///
/// Policy (pure, so it is unit-tested without clocks or actors):
/// - A value equal to what is on screen is dropped.
/// - The first change after a quiet `interval` is delivered at once (leading
///   edge), so a single step still feels instant.
/// - Changes inside the interval only replace a pending value; one trailing
///   flush delivers the newest one when the interval ends. The last report of
///   a burst is therefore never lost — the control never sticks on "3/40"
///   while the pass is really at "40/40".
struct StatusThrottle: Equatable {
    enum Decision: Equatable {
        /// Show this value now.
        case deliver(String)
        /// Call `flush(now:)` after this many seconds.
        case scheduleFlush(after: TimeInterval)
        /// Nothing to do (unchanged, or folded into an already scheduled flush).
        case drop
    }

    /// Minimum spacing between deliveries. 0.25 s ≈ 4 Hz.
    let interval: TimeInterval
    /// Value last delivered (or seeded by the caller's own direct write).
    private(set) var shown: String?
    /// Newest value waiting for the trailing flush.
    private(set) var pending: String?
    private(set) var flushScheduled = false
    private var lastDelivery: TimeInterval?

    init(interval: TimeInterval = 0.25, shown: String? = nil) {
        self.interval = interval
        self.shown = shown
    }

    mutating func submit(_ value: String, now: TimeInterval) -> Decision {
        if value == shown {
            // Newest state already on screen: an older pending value must
            // not be flushed over it.
            pending = nil
            return .drop
        }
        let quiet = lastDelivery.map { now - $0 >= interval } ?? true
        if !flushScheduled, quiet {
            shown = value
            lastDelivery = now
            pending = nil
            return .deliver(value)
        }
        pending = value
        if flushScheduled { return .drop }
        flushScheduled = true
        let elapsed = lastDelivery.map { now - $0 } ?? interval
        return .scheduleFlush(after: max(0, interval - elapsed))
    }

    /// The trailing edge. Returns the value to show, or nil when the burst
    /// ended on what is already on screen.
    mutating func flush(now: TimeInterval) -> String? {
        flushScheduled = false
        guard let value = pending else { return nil }
        pending = nil
        guard value != shown else { return nil }
        shown = value
        lastDelivery = now
        return value
    }
}

/// Thread-safe front for `StatusThrottle`. Sync engines report progress from
/// their own actors, so the throttle decision is made on the caller's side —
/// a dropped report costs a lock, not a main-actor hop.
///
/// `close()` ends the stream: the owner calls it on the main actor right
/// before it writes the final status (usually ""). Hops already queued check
/// the flag when they land, so a late progress string can never overwrite
/// the final value — the old unthrottled `Task { @MainActor … }` per report
/// had exactly that race.
final class ThrottledStatusSink: @unchecked Sendable {
    private let lock = NSLock()
    private var core: StatusThrottle
    private var closed = false
    private let clock: @Sendable () -> TimeInterval
    private let deliver: @MainActor @Sendable (String) -> Void

    /// - Parameters:
    ///   - shown: what the status reads right now, so an identical first
    ///     report is dropped.
    ///   - deliver: applies a value on the main actor.
    init(interval: TimeInterval = 0.25,
         shown: String? = nil,
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         deliver: @escaping @MainActor @Sendable (String) -> Void) {
        self.core = StatusThrottle(interval: interval, shown: shown)
        self.clock = clock
        self.deliver = deliver
    }

    func submit(_ value: String) {
        let decision: StatusThrottle.Decision = lock.withLock {
            closed ? .drop : core.submit(value, now: clock())
        }
        switch decision {
        case .drop:
            break
        case .deliver(let value):
            Task { @MainActor in self.apply(value) }
        case .scheduleFlush(let wait):
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
                let value: String? = self.lock.withLock {
                    self.closed ? nil : self.core.flush(now: self.clock())
                }
                guard let value else { return }
                await MainActor.run { self.apply(value) }
            }
        }
    }

    /// Stops every further delivery, including hops already in flight.
    func close() {
        lock.withLock { closed = true }
    }

    var isClosed: Bool { lock.withLock { closed } }

    @MainActor private func apply(_ value: String) {
        guard !isClosed else { return }
        deliver(value)
    }
}
