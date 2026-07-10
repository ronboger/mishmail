import Foundation

/// Pure decision for Gmail-style "go to mailbox" (g then i/s/t/…) while a
/// `/` search may be active. The destination must be the unfiltered view —
/// committed search uses the FTS path and ignores `selectedView`.
enum GoToMailbox {
    struct Plan: Equatable {
        /// Clear `searchText` and `committedSearch` before navigating.
        var clearSearch: Bool
        /// Write a new `selectedView` (ContentView onChange reloads).
        var changeView: Bool
        /// Reload immediately: destination already selected, so onChange will
        /// not fire, but search was cleared and the list is stale.
        var reloadImmediately: Bool
    }

    static func plan(destinationIsCurrent: Bool,
                     searchText: String,
                     committedSearch: String) -> Plan {
        let clearSearch = !searchText.isEmpty || !committedSearch.isEmpty
        return Plan(
            clearSearch: clearSearch,
            changeView: !destinationIsCurrent,
            reloadImmediately: destinationIsCurrent && clearSearch
        )
    }
}
