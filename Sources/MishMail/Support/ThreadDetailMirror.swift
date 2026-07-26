import Foundation

/// Main-actor copy of payloads the repository has already produced, so the
/// reading pane can paint without an `await`.
///
/// `ThreadDetailRepository` is an actor, so every read costs a round-trip:
/// MainActor → actor → MainActor. The return hop needs MainActor *free*, and
/// on the delete-advance path it is not — the same keystroke queues a row
/// removal, a list regroup and a detail rebuild ahead of it. Measured on the
/// demo inbox, that made `open.ready` 176–209 ms with cache **hits** costing
/// the same as misses: the lookup was never the cost, the hop was.
///
/// Holding the payload on the main actor removes the hop for the case that
/// matters — the neighbor the user is about to land on, already warmed by
/// `scheduleNeighborPrefetch`. The repository stays the source of truth; this
/// is a read-through shortcut that is allowed to miss.
///
/// Payloads are value types whose strings are copy-on-write, so mirroring one
/// shares the repository's buffers rather than duplicating them.
struct ThreadDetailMirror {
    private struct Entry {
        let revision: ThreadContentRevision
        /// Suppression is applied on the way *out* of the repository, so a
        /// payload built under a different set is not reusable.
        let suppressedIds: Set<String>
        let payload: ThreadDetailPayload
    }

    private var lru: ThreadDetailLRU<Entry>

    init(capacity: Int) {
        lru = ThreadDetailLRU<Entry>(capacity: capacity)
    }

    /// The mirrored payload, or nil when the caller must go to the repository.
    ///
    /// Deliberately non-mutating (no LRU touch): SwiftUI `body` reads this to
    /// seed a freshly identified pane, and `body` must be side-effect free.
    /// Eviction is therefore insertion-ordered, which is what a four-entry
    /// navigation window wants anyway.
    func payload(for threadId: String,
                 revision: ThreadContentRevision,
                 suppressing suppressedIds: Set<String>) -> ThreadDetailPayload? {
        guard let entry = lru.values[threadId],
              entry.revision == revision,
              entry.suppressedIds == suppressedIds else { return nil }
        return entry.payload
    }

    mutating func store(_ payload: ThreadDetailPayload,
                        for threadId: String,
                        revision: ThreadContentRevision,
                        suppressing suppressedIds: Set<String>) {
        lru.insert(
            Entry(revision: revision, suppressedIds: suppressedIds, payload: payload),
            for: threadId)
    }

    mutating func removeAll() {
        lru.removeAll()
    }
}
