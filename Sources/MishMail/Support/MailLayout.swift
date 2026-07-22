import CoreGraphics

/// How a conversation opens from the list (Settings → Appearance).
enum ThreadOpenStyle: String, CaseIterable {
    /// Superhuman-style: the conversation fills the whole window; Esc (or
    /// the back button) returns to the list.
    case fullWindow
    /// Outlook/Apple Mail-style: the conversation shows in a pane beside
    /// the list.
    case readingPane

    static let storageKey = "threadOpenStyle"
}

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
                     threadFocus: Bool = false,
                     fullWindowThreads: Bool = false) -> MailLayoutMode {
        // Superhuman-style open: there is no side-by-side reading pane at
        // all — you're either on the list or inside the conversation.
        if fullWindowThreads {
            return (threadFocus && hasSelection) ? .threadFocus : .list
        }
        // Focus needs a selected conversation; without one, fall through.
        if threadFocus, hasSelection { return .threadFocus }
        if readingPaneHidden { return .list }
        if width < threePaneMinimumWidth {
            return hasSelection ? .compactDetail : .list
        }
        return .threePane
    }
}
