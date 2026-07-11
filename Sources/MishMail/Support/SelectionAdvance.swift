import Foundation

/// Which row should be selected after removing one (or many) from a list —
/// the row below the focus, or the one above when the focus was last
/// (Gmail-style auto-advance after archive/trash).
enum SelectionAdvance {
    static func neighborId(in ids: [String], removing id: String) -> String? {
        // Missing id → nil (caller has nothing to advance from).
        guard ids.contains(id) else { return nil }
        return neighborId(in: ids, removing: [id], focus: id)
    }

    /// After removing a set of rows, land on the first surviving neighbor of
    /// `focus` (down, then up). If `focus` was not removed and still exists,
    /// keep it. Returns nil when the list is empty after the removal.
    static func neighborId(in ids: [String], removing removed: Set<String>,
                           focus: String?) -> String? {
        guard !ids.isEmpty else { return nil }
        if let focus, !removed.contains(focus), ids.contains(focus) {
            return focus
        }
        let focusIdx: Int = {
            if let focus, let i = ids.firstIndex(of: focus) { return i }
            // No focus / missing: treat as "before first" so we land on the
            // first survivor (covered by the forward walk below).
            return -1
        }()
        if focusIdx + 1 < ids.count {
            for i in (focusIdx + 1)..<ids.count where !removed.contains(ids[i]) {
                return ids[i]
            }
        }
        if focusIdx > 0 {
            for i in stride(from: focusIdx - 1, through: 0, by: -1)
            where !removed.contains(ids[i]) {
                return ids[i]
            }
        }
        // focusIdx == -1 and every later id was removed, or list was all removed.
        return nil
    }

    /// Inclusive range of ids between two anchors in display order (either
    /// direction). Nil when either id is missing from `order`.
    static func rangeIds(in order: [String], from: String, to: String) -> [String]? {
        guard let a = order.firstIndex(of: from),
              let b = order.firstIndex(of: to) else { return nil }
        let lo = min(a, b)
        let hi = max(a, b)
        return Array(order[lo...hi])
    }
}

/// In-memory list effect of an optimistic thread mutation.
///
/// Leave-list mutations (trash / archive out of inbox / spam) always remove
/// the row, even when the id is sticky under a read-state filter. Keep-ids
/// only pin mark-read/unread so the reading pane doesn't go blank — they must
/// not block trash/archive auto-advance under `is:unread`.
enum ThreadListOptimistic {
    enum Effect: Equatable {
        case updateInPlace
        case remove
    }

    /// Side effects applied when the row leaves the list. Encoded here so
    /// tests cover the keepIds/checked drop without instantiating MailStore.
    struct SideEffects: Equatable {
        var dropKeepId: Bool
        var dropChecked: Bool

        static let none = SideEffects(dropKeepId: false, dropChecked: false)
        static let onRemove = SideEffects(dropKeepId: true, dropChecked: true)
    }

    static func effect(leavesCurrentList: Bool) -> Effect {
        plan(leavesCurrentList: leavesCurrentList).effect
    }

    static func plan(leavesCurrentList: Bool) -> (effect: Effect, sideEffects: SideEffects) {
        if leavesCurrentList {
            return (.remove, .onRemove)
        }
        return (.updateInPlace, .none)
    }
}
