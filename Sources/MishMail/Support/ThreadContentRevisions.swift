import Foundation

/// Identity of one thread's reading-pane content, for cache validity.
///
/// `epoch` moves when every cached payload is suspect at once; `local` moves
/// when just this thread's message rows changed. Cache entries hold the
/// revision they were built from and compare it against the requested one, so
/// validity travels *with* the request — an in-flight prefetch can never
/// install a payload that a concurrent invalidation should have killed.
struct ThreadContentRevision: Equatable, Hashable, Sendable {
    var epoch: Int
    var local: Int
}

/// What a write actually changed.
///
/// Only message rows matter here. Label-only mutations — trash, archive, star,
/// mark-read — rewrite the *thread* row and leave every cached body valid, so
/// they report nothing.
enum ThreadContentChange: Equatable, Sendable {
    case none
    /// Message rows for exactly these thread ids changed.
    case threads(Set<String>)
    /// Rows were pruned or rebuilt wholesale; every cached payload is suspect.
    case everything
}

/// Per-thread content revisions for the reading-pane payload cache.
///
/// This replaced a single global counter that `reloadThreads()` bumped on
/// every call. Because a trash/archive/mark-read schedules a reload, one
/// keystroke invalidated all ten cached payloads — including the prev/next
/// neighbours `scheduleNeighborPrefetch` had warmed 50 ms earlier — so rapid
/// triage never landed on a warm payload and the prefetch did work that was
/// always discarded. Scoping revisions to the thread keeps those neighbours
/// alive across the unrelated mutations that dominate triage.
struct ThreadContentRevisions {
    /// Past this many tracked threads the map dwarfs the ten-entry cache it
    /// guards, so it collapses to an epoch bump. Over-invalidation is safe;
    /// under-invalidation would serve stale mail.
    static let maxTrackedThreads = 512

    private(set) var epoch = 0
    private var locals: [String: Int] = [:]

    /// Threads carrying a non-zero local counter (test observability).
    var trackedThreadCount: Int { locals.count }

    func revision(of threadId: String) -> ThreadContentRevision {
        ThreadContentRevision(epoch: epoch, local: locals[threadId] ?? 0)
    }

    /// Applies `change`. Returns whether anything moved, so callers only
    /// publish a refresh token when there is something to refresh.
    @discardableResult
    mutating func apply(_ change: ThreadContentChange) -> Bool {
        switch change {
        case .none:
            return false
        case .threads(let ids):
            guard !ids.isEmpty else { return false }
            for id in ids { locals[id, default: 0] &+= 1 }
            if locals.count > Self.maxTrackedThreads { bumpEpoch() }
            return true
        case .everything:
            bumpEpoch()
            return true
        }
    }

    /// Clearing the counters is what bounds the map. Safe because the epoch
    /// alone distinguishes every post-bump revision from every prior one.
    private mutating func bumpEpoch() {
        epoch &+= 1
        locals.removeAll(keepingCapacity: true)
    }
}
