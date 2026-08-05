import Foundation

/// Selection advance when a Priority-section row is unstarred but stays in
/// the inbox list.
///
/// Archive/trash use `SelectionAdvance` over full `displayOrder` because the
/// row leaves the list. Unstar is different: the thread remains in inbox, so
/// no leave-list auto-advance runs. On the next regroup the row simply moves
/// out of Priority into the date sections, and list selection follows it —
/// landing the user amid unstarred mail. These helpers restrict advance to
/// the Priority section's own order so unstar behaves like Gmail (next below
/// in section, else above). VIP-pinned and IMPORTANT-labeled rows that still
/// qualify after `isStarred=false` are not "leaving" and get no advance.
enum PrioritySectionAdvance {
    /// Ids among `targets` that currently sit in the priority section and will
    /// no longer qualify once unstarred (post-mutation state: isStarred=false).
    ///
    /// For each target: must be in `sectionIds` AND, with a copy whose
    /// `isStarred=false`, `PrioritySplit.qualifies` must be false. That keeps
    /// VIP-pinned threads and, under `.starredImportant`, IMPORTANT-labeled
    /// threads in place — no advance for those.
    static func idsLeavingSection(
        targets: [MailThread],
        sectionIds: Set<String>,
        mode: PrioritySplit.Mode,
        vipThreadIds: Set<String>,
        vipAlwaysPins: Bool,
        newerThan: Date? = nil
    ) -> Set<String> {
        // .off means no Priority section exists, so no row can leave it.
        guard mode != .off else { return [] }
        var leaving = Set<String>()
        for target in targets {
            guard sectionIds.contains(target.id) else { continue }
            var unstarred = target
            unstarred.isStarred = false
            if !PrioritySplit.qualifies(
                unstarred, mode: mode,
                vipThreadIds: vipThreadIds,
                vipAlwaysPins: vipAlwaysPins,
                newerThan: newerThan
            ) {
                leaving.insert(target.id)
            }
        }
        return leaving
    }

    /// Where selection/opened detail should land: reuse
    /// `SelectionAdvance.destinations` restricted to the priority section's
    /// display order (not the full inbox list).
    static func destinations(
        sectionOrder: [String],
        leaving: Set<String>,
        selected: String?,
        opened: String?
    ) -> SelectionAdvance.RemovalDestinations {
        SelectionAdvance.destinations(
            in: sectionOrder,
            removing: leaving,
            selected: selected,
            opened: opened)
    }
}
