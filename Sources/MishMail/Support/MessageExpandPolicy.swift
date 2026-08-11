import Foundation

/// How many message cards may keep a live body open at once.
///
/// The normal reading pane is single-active so HTML-heavy threads do not
/// accumulate WKWebViews. Side-by-side compose opens every sent card so the
/// draft can reference the full conversation (quoted trails still collapse
/// behind each card's "…" pill).
enum MessageExpandPolicy: Equatable {
    /// At most one sent card expanded (default reading pane).
    case single
    /// Any number of cards expanded (side-by-side compose).
    case multiple

    /// Toggle `id` open/closed under this policy.
    func applyingToggle(id: String, currently: Set<String>) -> Set<String> {
        let isOpen = currently.contains(id)
        switch self {
        case .single:
            return isOpen ? [] : [id]
        case .multiple:
            var next = currently
            if isOpen { next.remove(id) } else { next.insert(id) }
            return next
        }
    }

    /// Force-open `id` without collapsing siblings when multiple is allowed.
    func applyingExpand(id: String, currently: Set<String>) -> Set<String> {
        switch self {
        case .single:
            return [id]
        case .multiple:
            var next = currently
            next.insert(id)
            return next
        }
    }

    /// Default open set when a conversation first paints.
    /// - single: newest sent message only
    /// - multiple: every non-draft message id (drafts use `DraftMessageCard`)
    static func initialExpandedIds(
        policy: MessageExpandPolicy,
        nonDraftIds: [String],
        lastNonDraftId: String?
    ) -> Set<String> {
        switch policy {
        case .single:
            return lastNonDraftId.map { [$0] } ?? []
        case .multiple:
            return Set(nonDraftIds)
        }
    }
}
