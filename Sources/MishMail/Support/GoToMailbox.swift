import Foundation

/// Pure decision for Gmail-style "go to mailbox" (g then i/s/t/…) while a
/// `/` search may be active. The destination must be the unfiltered view —
/// committed search uses the FTS path and ignores `selectedView`.
///
/// Callers always exit full-window thread focus on go-to (even when every
/// flag below is false): same-mailbox `g i` must still return to the list.
enum GoToMailbox {
    struct Plan: Equatable {
        /// Clear `searchText` and `committedSearch` before navigating.
        var clearSearch: Bool
        /// Write a new `selectedView` (ContentView onChange reloads).
        var changeView: Bool
        /// Reload immediately: destination already selected, so onChange will
        /// not fire, but search was cleared and the list is stale.
        var reloadImmediately: Bool
        /// Always true — go-to is a navigation home, never stay inside a
        /// full-window conversation. Kept on the plan so tests document it.
        var exitThreadFocus: Bool
        /// Always true — go-to lands on the LIST, so any open conversation
        /// must close. Exiting thread focus alone is not enough: in
        /// compactDetail (narrow window, or Ask Mish taking width) the open
        /// conversation covers the list without thread focus being on, and a
        /// same-view `g i` would otherwise change nothing visible.
        var closeConversation: Bool
    }

    static func plan(destinationIsCurrent: Bool,
                     searchText: String,
                     committedSearch: String) -> Plan {
        let clearSearch = !searchText.isEmpty || !committedSearch.isEmpty
        return Plan(
            clearSearch: clearSearch,
            changeView: !destinationIsCurrent,
            reloadImmediately: destinationIsCurrent && clearSearch,
            exitThreadFocus: true,
            closeConversation: true
        )
    }
}
