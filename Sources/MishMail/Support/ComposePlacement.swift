import Foundation

/// Where the compose UI mounts relative to the mailbox chrome.
enum ComposePresentation: String, Equatable {
    /// Bottom-right floating card (Gmail/Notion dock).
    case floating
    /// Docked at the bottom of the reading pane so the thread stays visible.
    case inline
}

/// Pure placement rules for compose — kept free of MailStore so tests can
/// cover reply-vs-forward without spinning up the app.
enum ComposePlacement {
    /// Prefer inline reply when the reading pane already shows this thread.
    /// New mail, forwards, and off-thread drafts stay floating.
    static func preferred(
        replyTo: Message?,
        editDraft: Message? = nil,
        forward: Bool,
        selectedThreadId: String?,
        readingPaneHidden: Bool
    ) -> ComposePresentation {
        if forward { return .floating }
        if readingPaneHidden { return .floating }
        let threadId = replyTo?.threadId ?? editDraft?.threadId
        guard let threadId, let selectedThreadId else { return .floating }
        return threadId == selectedThreadId ? .inline : .floating
    }

    /// Whether an open compose request should render in the given thread's
    /// reading pane (inline dock).
    static func showsInline(inThread threadId: String,
                            presentation: ComposePresentation,
                            replyTo: Message?,
                            editDraft: Message?) -> Bool {
        guard presentation == .inline else { return false }
        let composeThread = replyTo?.threadId ?? editDraft?.threadId
        return composeThread == threadId
    }
}
