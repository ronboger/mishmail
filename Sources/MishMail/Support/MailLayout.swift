import CoreGraphics

enum MailLayoutMode: Equatable {
    case list
    case compactDetail
    case threePane
    /// Conversation fills the window (sidebar + list hidden). Entered via ⌘↩.
    case threadFocus
}

enum MailLayout {
    /// Below this width, keeping sidebar + list + message visible makes the
    /// reading pane too narrow to read. Compact mode swaps list and message.
    static let threePaneMinimumWidth: CGFloat = 1_080

    static func mode(width: CGFloat, readingPaneHidden: Bool,
                     hasSelection: Bool,
                     threadFocus: Bool = false) -> MailLayoutMode {
        // Focus needs a selected conversation; without one, fall through.
        if threadFocus, hasSelection { return .threadFocus }
        if readingPaneHidden { return .list }
        if width < threePaneMinimumWidth {
            return hasSelection ? .compactDetail : .list
        }
        return .threePane
    }
}
