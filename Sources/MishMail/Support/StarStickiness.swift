import Foundation

/// How long just-unstarred pins (`starStateKeepIds`) should survive.
///
/// - `session`: star-gated lists (Starred mailbox, `is:starred`, starredOnly
///   views). Pins last until the view/filter changes so batch triage works.
/// - `thread`: category-hide pin-through only. Pins last while the thread is
///   selected or multi-checked; leave the thread and the pin drops so
///   unstarred Updates/Promo mail does not clog Primary forever.
/// - `none`: no star gate active.
enum StarStickinessPolicy: Equatable {
    case none
    case session
    case thread
}

/// Pure helpers for unstar stickiness policy and category-hide leave checks.
/// Hostless tests call these without AppKit / MailStore.
enum StarStickiness {
    /// Resolve stickiness policy from list state.
    ///
    /// When a committed `/` search is active it replaces chips/view filters
    /// (same as `reloadThreads`), so only search operators can arm a gate.
    /// Session gates win over thread when both could apply.
    static func policy(
        committedSearch: String,
        chipsHide: Set<String> = [],
        chipsLabelId: String? = nil,
        viewIsStarred: Bool = false,
        viewLabelIsStarred: Bool = false,
        savedStarredOnly: Bool = false,
        savedHide: Set<String> = [],
        savedLabelId: String? = nil,
        savedExcludePromotionsLegacy: Bool = false
    ) -> StarStickinessPolicy {
        let search = committedSearch.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty {
            let parsed = SearchQuery.parse(search)
            if parsed.starred { return .session }
            if parsed.labels.contains(where: {
                $0.caseInsensitiveCompare("starred") == .orderedSame
            }) { return .session }
            // Search replaces chips/view filters — no thread-long hide gate.
            return .none
        }

        if viewIsStarred || viewLabelIsStarred { return .session }
        if chipsLabelId == "STARRED" { return .session }
        if savedStarredOnly || savedLabelId == "STARRED" { return .session }

        if !chipsHide.isEmpty { return .thread }
        if !savedHide.isEmpty { return .thread }
        if savedExcludePromotionsLegacy { return .thread }
        return .none
    }

    /// Selection intents that should drop unretained thread-long pins.
    /// `.restoreFocus` is exempt so Undo re-select does not yank a pin the
    /// user did not intentionally leave.
    static func selectionDropsThreadPins(_ intent: ThreadSelectionIntent) -> Bool {
        switch intent {
        case .restoreFocus: return false
        case .click, .browse, .autoAdvance, .explicitOpen, .quiet: return true
        }
    }

    /// Ids in `keepIds` that are no longer retained by selection or multi-check
    /// under thread-long policy. Empty when policy is not `.thread`, or when
    /// a selection intent is present and exempt (`.restoreFocus`).
    ///
    /// Pass `selectionIntent: nil` for uncheck / clear-checked passes (always
    /// drop unretained pins under `.thread`).
    static func idsToDrop(
        keepIds: Set<String>,
        selectedId: String?,
        checkedIds: Set<String>,
        policy: StarStickinessPolicy,
        selectionIntent: ThreadSelectionIntent?
    ) -> Set<String> {
        guard policy == .thread else { return [] }
        if let intent = selectionIntent, !selectionDropsThreadPins(intent) {
            return []
        }
        return keepIds.filter { id in
            id != selectedId && !checkedIds.contains(id)
        }
    }

    /// Whether the thread sits in any of the hidden Gmail categories.
    /// Mirrors `CategoryHide.apply` membership (denorm for promo/social,
    /// substring on `labelIds` for Updates/Forums — same as SQL `LIKE %cat%`).
    static func isInHiddenCategory(
        hide: Set<String>,
        inPromotions: Bool,
        inSocial: Bool,
        labelIds: String
    ) -> Bool {
        for cat in hide {
            switch cat {
            case "CATEGORY_PROMOTIONS":
                if inPromotions { return true }
            case "CATEGORY_SOCIAL":
                if inSocial { return true }
            default:
                if labelIds.contains(cat) { return true }
            }
        }
        return false
    }

    /// Unstarred + in a hidden category + not sticky → leaves a category-hide
    /// filtered list (Primary with hide chips). Star or keepIds pin through.
    static func leavesDueToCategoryHide(
        hide: Set<String>,
        inPromotions: Bool,
        inSocial: Bool,
        labelIds: String,
        isStarred: Bool,
        isKept: Bool
    ) -> Bool {
        if hide.isEmpty { return false }
        if isStarred || isKept { return false }
        return isInHiddenCategory(
            hide: hide,
            inPromotions: inPromotions,
            inSocial: inSocial,
            labelIds: labelIds)
    }
}
