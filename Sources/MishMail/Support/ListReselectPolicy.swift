import Foundation

/// When to mount a same-row reselect handler on a SwiftUI `List(selection:)`.
///
/// On macOS, a permanent `TapGesture` / `contentShape` on every row steals
/// hits from `List` selection — unselected rows become hard or impossible to
/// click. Mount the handler only on the already-selected row (mirrors
/// `ThreadListView`'s selected-only open overlay and the sidebar reselect
/// path for re-clicking Inbox to clear a committed `/` search).
enum ListReselectPolicy {
    /// `true` only when this row is already selected, so cross-row clicks
    /// still reach the List selection binding.
    static func mountsHandler<T: Equatable>(row: T, selected: T) -> Bool {
        row == selected
    }
}
