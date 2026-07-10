import Foundation

/// Pure ordering logic for the account switcher's drag-to-reorder. Kept
/// separate from `MailStore` so it's covered by the hostless test target —
/// no GRDB, no UserDefaults, just array math.
enum AccountOrder {
    /// Applies a drag-reorder move to an ordered id list, mirroring SwiftUI's
    /// `Array.move(fromOffsets:toOffset:)` / `List.onMove` semantics. Hand-
    /// rolled (rather than calling the SwiftUI extension) so this stays
    /// SwiftUI-free and testable from the hostless test target.
    static func moved(_ ids: [String], from source: IndexSet, to destination: Int) -> [String] {
        var result = ids
        let moving = source.map { result[$0] }
        for index in source.sorted(by: >) {
            result.remove(at: index)
        }
        let adjustedDestination = destination - source.filter { $0 < destination }.count
        result.insert(contentsOf: moving, at: adjustedDestination)
        return result
    }

    /// Reconciles a persisted account order against the live set of account
    /// ids: ids still live keep their persisted relative order; ids no
    /// longer live (account removed) are dropped; live ids missing from the
    /// persisted order (a newly added account) are appended at the end, in
    /// their `live` order.
    static func reconciled(persisted: [String], live: [String]) -> [String] {
        let liveSet = Set(live)
        var result = persisted.filter { liveSet.contains($0) }
        let known = Set(result)
        for id in live where !known.contains(id) {
            result.append(id)
        }
        return result
    }
}
