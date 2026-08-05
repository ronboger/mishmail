import Foundation

/// Keyboard-nav neighbors of a thread about to be starred into Priority.
///
/// When Priority split is on, starring the focused row re-partitions it into
/// the Priority section at the top of the list. Selection tracks thread id, so
/// the list scrolls to Priority and the next Down/j (`moveSelection(+1)` over
/// the rebuilt `displayOrder`) lands on a neighbor *inside* Priority — another
/// starred thread. That breaks the user's place in the date groups they were
/// reading through.
///
/// Capture pre-star neighbors (skipping co-starred ids, which also leave their
/// original spots) and consume them on the next single-step move while focus
/// is still the starred thread. Hostless pure helpers so unit tests cover the
/// geometry without AppKit / MailStore.
enum StarNavAnchor {
    struct Anchor: Equatable {
        /// Thread that was starred (and is still selected).
        var fromId: String
        /// First id after `fromId` in pre-star order that is not among the
        /// starred set. Nil at the bottom of the list (or when only starred
        /// ids remain below).
        var nextId: String?
        /// First id before `fromId` not in the starred set. Nil at the top.
        var prevId: String?
    }

    /// Neighbors of `focusId` in `displayOrder`, skipping every id in
    /// `starredIds` (the focus itself and any co-starred bulk targets).
    /// Returns nil when focus is missing from order.
    static func anchor(
        displayOrder: [String],
        focusId: String,
        starredIds: Set<String>
    ) -> Anchor? {
        guard let focusIdx = displayOrder.firstIndex(of: focusId) else {
            return nil
        }
        var nextId: String?
        if focusIdx + 1 < displayOrder.count {
            for i in (focusIdx + 1)..<displayOrder.count
            where !starredIds.contains(displayOrder[i]) {
                nextId = displayOrder[i]
                break
            }
        }
        var prevId: String?
        if focusIdx > 0 {
            for i in stride(from: focusIdx - 1, through: 0, by: -1)
            where !starredIds.contains(displayOrder[i]) {
                prevId = displayOrder[i]
                break
            }
        }
        return Anchor(fromId: focusId, nextId: nextId, prevId: prevId)
    }

    /// Whether a stored anchor still applies for this keyboard step.
    ///
    /// Only single-step ±1 moves while focus remains on `anchorFromId`, and
    /// only when the candidate target is still present in the current order.
    /// Wrong selection, multi-step jumps, or a vanished target → do not apply
    /// (caller clears the anchor and falls through to normal navigation).
    static func applies(
        currentSelectedId: String?,
        anchorFromId: String,
        delta: Int,
        targetPresent: Bool
    ) -> Bool {
        guard currentSelectedId == anchorFromId else { return false }
        guard delta == 1 || delta == -1 else { return false }
        return targetPresent
    }

    /// Candidate id for a ±1 step, or nil when that side has no neighbor.
    static func targetId(in anchor: Anchor, delta: Int) -> String? {
        if delta > 0 { return anchor.nextId }
        if delta < 0 { return anchor.prevId }
        return nil
    }

    /// Stable row to pin the viewport on after the starred row re-partitions
    /// into Priority. Prefer the Down neighbor so the user keeps looking at
    /// the date-group content that was below the starred row; fall back to
    /// the Up neighbor at the bottom of the list.
    static func holdId(from anchor: Anchor) -> String? {
        anchor.nextId ?? anchor.prevId
    }

    /// Whether the star-scroll hold should counter NSTableView's scroll-to-
    /// selected after regroup. Only when: a hold row exists and remains in
    /// the new order, selection is still the starred thread, and that thread
    /// is now in Priority (the re-partition that causes the jump actually
    /// happened). Hostless so unit tests cover the decision without AppKit.
    static func shouldRestoreScrollHold(
        holdId: String?,
        selectedId: String?,
        holdPresentInOrder: Bool,
        selectedInPriority: Bool
    ) -> Bool {
        guard let holdId, !holdId.isEmpty else { return false }
        guard holdPresentInOrder else { return false }
        guard let selectedId, selectedId != holdId else { return false }
        return selectedInPriority
    }
}
