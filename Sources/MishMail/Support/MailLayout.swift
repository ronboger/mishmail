import CoreGraphics

enum MailLayoutMode: Equatable {
    case list
    case compactDetail
    case threePane
}

enum MailLayout {
    /// Below this width, keeping sidebar + list + message visible makes the
    /// reading pane too narrow to read. Compact mode swaps list and message.
    static let threePaneMinimumWidth: CGFloat = 1_080

    static func mode(width: CGFloat, readingPaneHidden: Bool,
                     hasSelection: Bool) -> MailLayoutMode {
        if readingPaneHidden { return .list }
        if width < threePaneMinimumWidth {
            return hasSelection ? .compactDetail : .list
        }
        return .threePane
    }
}
