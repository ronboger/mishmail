import Foundation

/// Maps the mailbox on screen into saved-view fields for "Save as view…".
///
/// A saved view starts from the inbox (`inInbox`, not snoozed) unless
/// `showArchived` is set, and narrows from there with one label, a starred
/// flag and the chips. The filter bar shows in every mailbox, so saving from
/// Sent or a label has to write that mailbox into those fields — otherwise
/// the saved view lists inbox mail.
///
/// Pure and on primitive types: `MailboxView` and `FilterChips` are app-target
/// only. The call site maps `MailboxView` to `Source`.
enum SavedViewBase {
    enum Source: Equatable {
        case inbox
        case account(String)
        case promotions
        case social
        case starred
        case allMail
        case sent
        case label(account: String, labelId: String, name: String)
        /// Trash, Drafts, Snoozed, Reminders, Labels, Scheduled, Outbox, and
        /// a saved view itself: no saved-view fields describe these lists.
        case unsupported
    }

    /// The part of a saved view that depends on the base mailbox. The other
    /// chips (unread, sender, dates…) do not and are copied as they are.
    struct Fields: Equatable {
        var accountId: String?
        var labelId: String?
        var labelName: String?
        var labelExclude: Bool
        var starredOnly: Bool
        var showArchived: Bool
        var categoryShow: Set<String>
    }

    /// nil = a saved view cannot express this list; the caller hides the
    /// "Save as view…" button instead of saving a different list.
    static func fields(for source: Source,
                       activeAccountId: String?,
                       chipsLabelId: String?,
                       chipsLabelName: String?,
                       chipsLabelExclude: Bool,
                       chipsShowArchived: Bool,
                       chipsCategoryShow: Set<String>) -> Fields? {
        var out = Fields(accountId: activeAccountId,
                         labelId: chipsLabelId,
                         labelName: chipsLabelName,
                         labelExclude: chipsLabelExclude,
                         starredOnly: false,
                         showArchived: chipsShowArchived,
                         categoryShow: chipsCategoryShow)
        // A saved view holds one label, so a base label and a label chip
        // ("has both") do not fit.
        func baseLabel(_ id: String, _ name: String) -> Bool {
            guard chipsLabelId == nil else { return false }
            out.labelId = id
            out.labelName = name
            // "Clear label filter" leaves the exclude flag behind.
            out.labelExclude = false
            return true
        }
        // The category tabs are inbox mail; "Show archived" does not widen
        // them on screen. Shown categories are OR-ed, so another shown
        // category would widen the tab instead of narrowing it.
        func baseCategory(_ category: String) -> Bool {
            guard chipsCategoryShow.isSubset(of: [category]) else { return false }
            out.categoryShow = [category]
            out.showArchived = false
            return true
        }
        switch source {
        case .inbox:
            break
        case .account(let account):
            out.accountId = account
        case .promotions:
            guard baseCategory("CATEGORY_PROMOTIONS") else { return nil }
        case .social:
            guard baseCategory("CATEGORY_SOCIAL") else { return nil }
        case .starred:
            out.starredOnly = true
            out.showArchived = true
        case .allMail:
            out.showArchived = true
        case .sent:
            // `MailStore.filterThreads` maps the SENT system label to `inSent`.
            guard baseLabel("SENT", "Sent") else { return nil }
            out.showArchived = true
        case .label(let account, let labelId, let name):
            guard baseLabel(labelId, name) else { return nil }
            // Label ids are only unique within an account.
            out.accountId = account
            out.showArchived = true
        case .unsupported:
            return nil
        }
        return out
    }

    /// Title for a saved view's label id that is not a user label, so the
    /// editor's Label picker has a row for it (a view saved from Sent).
    static func unlistedLabelTitle(_ labelId: String) -> String {
        labelId == "SENT" ? "Sent" : labelId
    }
}
