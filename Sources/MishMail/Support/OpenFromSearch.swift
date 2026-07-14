import Foundation

/// Pure helpers for opening a thread from the `/` search panel.
///
/// The reading pane resolves the open conversation with
/// `threads.first { $0.id == selectedThreadId }` — so selecting an id that
/// is not yet in `threads` (async reload still in flight, or a typeahead hit
/// outside the current mailbox page) leaves the detail blank. These helpers
/// keep the chosen thread visible across that gap.
enum OpenFromSearch {
    /// Insert `opening` at the front of `threads` when it is not already present.
    static func ensuringVisible(opening: MailThread, in threads: [MailThread]) -> [MailThread] {
        if threads.contains(where: { $0.id == opening.id }) { return threads }
        return [opening] + threads
    }

    /// After an async list reload, re-attach a still-selected thread that the
    /// new filter omitted so the reading pane does not go blank mid-open.
    static func mergingPinned(
        selectedId: String?,
        previous: [MailThread],
        reloaded: [MailThread]
    ) -> [MailThread] {
        guard let selectedId,
              !reloaded.contains(where: { $0.id == selectedId }),
              let pin = previous.first(where: { $0.id == selectedId })
        else { return reloaded }
        return [pin] + reloaded
    }
}
