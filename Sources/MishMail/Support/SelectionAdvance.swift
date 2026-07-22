import Foundation

/// Why list focus changed. Browsing deliberately coalesces the expensive
/// reading pane; clicks, explicit opens, and destructive auto-advance must
/// replace the pane immediately. Quiet is the Superhuman-style pre-highlight
/// of the top row: selection only, the conversation must never open for it.
enum ThreadSelectionIntent: String, Equatable {
    case click
    case browse
    case autoAdvance
    case explicitOpen
    case quiet
    case restoreFocus

    var opensDetailImmediately: Bool {
        switch self {
        case .browse, .quiet: return false
        case .click, .autoAdvance, .explicitOpen, .restoreFocus: return true
        }
    }

    /// Only direct user gestures may reveal a pane the user deliberately hid.
    var revealsReadingPane: Bool {
        self == .click || self == .explicitOpen
    }

    /// Draft redirection is navigation, not a side effect of triage or Undo.
    var redirectsDraftToCompose: Bool {
        self == .click || self == .explicitOpen
    }
}

/// Which row should be selected after removing one (or many) from a list —
/// the row below the focus, or the one above when the focus was last
/// (Gmail-style auto-advance after archive/trash).
enum SelectionAdvance {
    struct RemovalDestinations: Equatable {
        var selectedId: String?
        var openedId: String?
        var selectedWasRemoved: Bool
        var openedWasRemoved: Bool
    }

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

    /// Advance list focus and mounted detail independently. During keyboard
    /// browsing they can intentionally differ, so removing one must not steal
    /// or blank the other.
    static func destinations(in ids: [String], removing removed: Set<String>,
                             selected: String?, opened: String?)
        -> RemovalDestinations {
        let selectedWasRemoved = selected.map(removed.contains) ?? false
        let openedWasRemoved = opened.map(removed.contains) ?? false
        return RemovalDestinations(
            selectedId: selectedWasRemoved
                ? neighborId(in: ids, removing: removed, focus: selected)
                : selected,
            openedId: openedWasRemoved
                ? neighborId(in: ids, removing: removed, focus: opened)
                : opened,
            selectedWasRemoved: selectedWasRemoved,
            openedWasRemoved: openedWasRemoved)
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

/// Pure list-focus navigation: move highlight without I/O.
///
/// `indexById` is the O(1) map rebuilt whenever `displayOrder` changes. When
/// empty (or missing an id), falls back to a linear scan of `order`.
enum ThreadListNavigation {
    /// Next focused id after moving `delta` steps (-1 / +1, or larger jumps).
    /// Returns nil only when `order` is empty.
    static func move(selected: String?, delta: Int, order: [String],
                     indexById: [String: Int] = [:]) -> String? {
        guard !order.isEmpty else { return nil }
        let idx: Int = {
            guard let selected else {
                return delta > 0 ? -1 : 0
            }
            if let i = indexById[selected] { return i }
            if let i = order.firstIndex(of: selected) { return i }
            return delta > 0 ? -1 : 0
        }()
        let next = min(max(idx + delta, 0), order.count - 1)
        return order[next]
    }

    /// Build the id→index map used by `move` and multi-select range.
    static func indexMap(for order: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        map.reserveCapacity(order.count)
        for (i, id) in order.enumerated() { map[id] = i }
        return map
    }
}

/// Whether a keyboard-driven selection change should open the reading pane
/// immediately or through the j/k debounce.
///
/// Browsing with j/k debounces the detail open so held-down keys don't churn
/// the pane. But when the selection moved because the opened row left the
/// list (trash/archive/spam auto-advance), the debounce leaves the pane on a
/// dangling id — it falls to the empty placeholder, tears down the detail
/// view, and rebuilds it from scratch after the delay. Open immediately so
/// the pane hands off to the neighbor in the same update.
enum DetailOpenPolicy {
    /// Quiet period before hydrating the reading pane for keyboard focus.
    /// Long enough that key-repeat (and a busy main thread stretching inter-key
    /// gaps past ~30 ms) still coalesces to one open; short enough that a
    /// deliberate pause still feels like live preview.
    static let settleNanoseconds: UInt64 = 150_000_000  // 150 ms

    static func opensImmediately(openedThreadId: String?,
                                 listedIds: some Sequence<String>) -> Bool {
        guard let openedThreadId else { return false }
        return !listedIds.contains(openedThreadId)
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

    /// Insertion position matching `ORDER BY sortDate DESC, id DESC`.
    /// Used when Undo restores a row that was optimistically removed.
    static func insertionIndex(for thread: MailThread, in rows: [MailThread],
                               inboundSort: Bool) -> Int {
        let key = ThreadListPaging.activityDate(of: thread, inboundSort: inboundSort)
        return rows.firstIndex { existing in
            let existingKey = ThreadListPaging.activityDate(
                of: existing, inboundSort: inboundSort)
            if existingKey != key { return existingKey < key }
            return existing.id < thread.id
        } ?? rows.endIndex
    }
}
