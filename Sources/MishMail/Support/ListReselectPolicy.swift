import Foundation

/// When a same-row reselect handler should participate in hit-testing on a
/// SwiftUI `List(selection:)` row.
///
/// On macOS, a permanent `TapGesture` / `contentShape` on every row steals
/// hits from `List` selection — unselected rows become hard or impossible to
/// click. Keep one view identity and gate the gesture with
/// `GestureMask` (`.gesture` when selected, `.subviews` otherwise) so
/// cross-row clicks still reach the selection binding. Mirrors
/// `ThreadListView`'s selected-only open overlay and the sidebar reselect
/// path for re-clicking Inbox to clear a committed `/` search.
enum ListReselectPolicy {
    /// `true` only when this row is already selected.
    static func mountsHandler<T: Equatable>(row: T, selected: T) -> Bool {
        row == selected
    }
}
