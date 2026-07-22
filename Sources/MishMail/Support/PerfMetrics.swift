import Foundation
import os

/// Lightweight measurement harness for scale decisions and search jank.
///
/// **Always** emits `OSSignposter` intervals (near-zero cost when Instruments
/// is not recording). Console lines only when explicitly enabled.
///
/// ### Enable console logs
/// - Env: `MISHMAIL_PERF=1` (e.g. `PERF=1 make run DEMO=0`)
/// - Or: `defaults write dev.ronboger.MishMail.debug perf.metrics.enabled -bool YES`
///
/// ### Instruments
/// Profile the Debug app → Time Profiler or Points of Interest.
/// Filter subsystem `dev.ronboger.MishMail.perf`.
///
/// ### What the events mean (decision map)
/// | Event | If slow… |
/// |-------|----------|
/// | `search.preview` | `/` typing dropdown FTS — fix live search path |
/// | `search.contacts` | Contact filter on main thread while typing |
/// | `reload.list` | Thread list SQL (indexes / LIMIT / filters) |
/// | `reload.counts` | Sidebar badge SQL (“badge rewrite”) |
/// | `reload.vip` | VIP hit scan on loaded rows |
/// | `reload.total` | Whole reload (compare to list+counts+vip) |
/// | `open.headers` | Thread open header projection |
/// | `open.body` | Body hydrate on expand |
/// | `open.html` | HTML document assembly/load through stable WebView height |
/// | `sync.flush` | Chunked write transaction |
/// | `sync.fetchAll` | Full backfill pass wall time |
/// | `sync.blocklist` | applyBlocklist scan |
enum PerfMetrics {
    static let subsystem = "dev.ronboger.MishMail.perf"

    private static let logger = Logger(subsystem: subsystem, category: "timing")
    private static let signposter = OSSignposter(
        logger: Logger(subsystem: subsystem, category: "signpost"))

    /// Console logging on/off. Signposts always fire.
    /// Cached at first use — env never changes mid-run; flipping the
    /// UserDefaults key requires a relaunch (acceptable for a debug harness).
    static var isLoggingEnabled: Bool { loggingEnabled }

    private static let loggingEnabled: Bool = {
        if ProcessInfo.processInfo.environment["MISHMAIL_PERF"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: "perf.metrics.enabled")
    }()

    /// Named intervals. Keep short and stable — Instruments groups by name.
    enum Event: String, CaseIterable {
        case searchPreview = "search.preview"
        case searchContacts = "search.contacts"
        case reloadList = "reload.list"
        case reloadCounts = "reload.counts"
        case reloadVIP = "reload.vip"
        case reloadTotal = "reload.total"
        case openHeaders = "open.headers"
        case openBody = "open.body"
        case openHTML = "open.html"
        case syncFlush = "sync.flush"
        case syncFetchAll = "sync.fetchAll"
        case syncBlocklist = "sync.blocklist"
        /// Per-id getMessage retry / exhaustion (history catch-up).
        case syncGetRetry = "sync.getRetry"
        /// History sync refused to advance historyId (retry-exhausted ids).
        case syncHistoryPartial = "sync.historyPartial"
        /// ThreadListView regroup / displayOrder rebuild.
        case listGroup = "list.group"
        /// Load-older page fetch.
        case pageLoadMore = "page.loadMore"
        /// List focus move (↓ / j) — should stay under one frame.
        case navFocus = "nav.focus"
        /// Reading-pane open after keyboard settle.
        case navDetailOpen = "nav.detailOpen"
    }

    /// One finished sample (ring buffer for dump / tests).
    struct Sample: Equatable {
        let event: String
        let ms: Double
        let meta: String
        let at: Date
    }

    private static let lock = NSLock()
    private static var ring: [Sample] = []
    private static let ringCap = 64

    /// Last N samples (newest last). For tests / debugger.
    static func recentSamples() -> [Sample] {
        lock.lock(); defer { lock.unlock() }
        return ring
    }

    /// Clear the ring (tests).
    static func resetSamples() {
        lock.lock(); defer { lock.unlock() }
        ring.removeAll(keepingCapacity: true)
    }

    // MARK: - Measure

    /// Sync work: signpost + optional log + ring sample.
    @discardableResult
    static func measure<T>(_ event: Event, meta: String = "",
                           _ body: () throws -> T) rethrows -> T {
        let interval = begin(event, meta: meta)
        do {
            let value = try body()
            interval.end()
            return value
        } catch {
            interval.end(extraMeta: "error")
            throw error
        }
    }

    /// Async work (DB reads, network-bound helpers).
    @discardableResult
    static func measureAsync<T>(_ event: Event, meta: String = "",
                                _ body: () async throws -> T) async rethrows -> T {
        let interval = begin(event, meta: meta)
        do {
            let value = try await body()
            interval.end()
            return value
        } catch {
            interval.end(extraMeta: "error")
            throw error
        }
    }

    /// Manual begin/end when the work span doesn't fit a single closure
    /// (e.g. multi-step `reloadThreads` with intermediate timings).
    struct Interval {
        fileprivate let event: Event
        fileprivate let meta: String
        fileprivate let state: OSSignpostIntervalState
        fileprivate let t0: CFAbsoluteTime

        func end(extraMeta: String = "") {
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            PerfMetrics.endSignpost(event, state: state)
            let combined = [meta, extraMeta].filter { !$0.isEmpty }.joined(separator: " ")
            record(event, ms: ms, meta: combined)
        }
    }

    static func begin(_ event: Event, meta: String = "") -> Interval {
        Interval(
            event: event,
            meta: meta,
            state: beginSignpost(event),
            t0: CFAbsoluteTimeGetCurrent())
    }

    // MARK: - Signpost names (must be StaticString)

    private static func beginSignpost(_ event: Event) -> OSSignpostIntervalState {
        switch event {
        case .searchPreview: return signposter.beginInterval("search.preview")
        case .searchContacts: return signposter.beginInterval("search.contacts")
        case .reloadList: return signposter.beginInterval("reload.list")
        case .reloadCounts: return signposter.beginInterval("reload.counts")
        case .reloadVIP: return signposter.beginInterval("reload.vip")
        case .reloadTotal: return signposter.beginInterval("reload.total")
        case .openHeaders: return signposter.beginInterval("open.headers")
        case .openBody: return signposter.beginInterval("open.body")
        case .openHTML: return signposter.beginInterval("open.html")
        case .syncFlush: return signposter.beginInterval("sync.flush")
        case .syncFetchAll: return signposter.beginInterval("sync.fetchAll")
        case .syncBlocklist: return signposter.beginInterval("sync.blocklist")
        case .syncGetRetry: return signposter.beginInterval("sync.getRetry")
        case .syncHistoryPartial: return signposter.beginInterval("sync.historyPartial")
        case .listGroup: return signposter.beginInterval("list.group")
        case .pageLoadMore: return signposter.beginInterval("page.loadMore")
        case .navFocus: return signposter.beginInterval("nav.focus")
        case .navDetailOpen: return signposter.beginInterval("nav.detailOpen")
        }
    }

    private static func endSignpost(_ event: Event, state: OSSignpostIntervalState) {
        switch event {
        case .searchPreview: signposter.endInterval("search.preview", state)
        case .searchContacts: signposter.endInterval("search.contacts", state)
        case .reloadList: signposter.endInterval("reload.list", state)
        case .reloadCounts: signposter.endInterval("reload.counts", state)
        case .reloadVIP: signposter.endInterval("reload.vip", state)
        case .reloadTotal: signposter.endInterval("reload.total", state)
        case .openHeaders: signposter.endInterval("open.headers", state)
        case .openBody: signposter.endInterval("open.body", state)
        case .openHTML: signposter.endInterval("open.html", state)
        case .syncFlush: signposter.endInterval("sync.flush", state)
        case .syncFetchAll: signposter.endInterval("sync.fetchAll", state)
        case .syncBlocklist: signposter.endInterval("sync.blocklist", state)
        case .syncGetRetry: signposter.endInterval("sync.getRetry", state)
        case .syncHistoryPartial: signposter.endInterval("sync.historyPartial", state)
        case .listGroup: signposter.endInterval("list.group", state)
        case .pageLoadMore: signposter.endInterval("page.loadMore", state)
        case .navFocus: signposter.endInterval("nav.focus", state)
        case .navDetailOpen: signposter.endInterval("nav.detailOpen", state)
        }
    }

    // MARK: - Internals

    private static func record(_ event: Event, ms: Double, meta: String) {
        let sample = Sample(event: event.rawValue, ms: ms, meta: meta, at: Date())
        lock.lock()
        ring.append(sample)
        if ring.count > ringCap { ring.removeFirst(ring.count - ringCap) }
        lock.unlock()

        guard isLoggingEnabled else { return }
        // Skip sub-millisecond noise for sync micro-chunks unless ≥ 1 ms.
        if ms < 1.0, event == .syncFlush { return }
        if meta.isEmpty {
            logger.info("\(event.rawValue, privacy: .public) \(ms, format: .fixed(precision: 1))ms")
        } else {
            logger.info("\(event.rawValue, privacy: .public) \(ms, format: .fixed(precision: 1))ms \(meta, privacy: .public)")
        }
    }
}
