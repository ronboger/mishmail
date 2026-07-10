import Foundation

/// Pure helper for Phase 2 neighbor-thread prefetch.
enum NeighborPrefetch {
    /// Previous and next thread ids in `displayOrder` around `selected`.
    /// Either side may be nil at list ends or when selection is missing.
    static func neighbors(selected: String?, in order: [String]) -> (prev: String?, next: String?) {
        guard let selected, let idx = order.firstIndex(of: selected) else {
            return (nil, nil)
        }
        let prev = idx > 0 ? order[idx - 1] : nil
        let next = idx + 1 < order.count ? order[idx + 1] : nil
        return (prev, next)
    }
}
