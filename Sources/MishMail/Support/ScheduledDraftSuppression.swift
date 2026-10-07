import Foundation

/// Which Gmail drafts MishMail hides because their content is already on
/// its way out: the one in the undo-send window, and every draft a
/// scheduled row was composed from.
///
/// A scheduled message keeps its Gmail draft until it sends. If that draft
/// stayed reachable ("Continue draft"), the user could send it by hand and
/// the scheduled row would send the old text again the next morning. The
/// scheduled part is derived from the rows on every reload, so it survives
/// a relaunch and ends the moment a row is edited, discarded or sent.
enum ScheduledDraftSuppression {
    static func suppressedDraftIds(pendingSendDraftIds: Set<String>,
                                   scheduledDraftIds: [String?]) -> Set<String> {
        var ids = pendingSendDraftIds
        for case let id? in scheduledDraftIds where !id.isEmpty {
            ids.insert(id)
        }
        return ids
    }

    /// Suppressed drafts whose conversation is not known yet (the Drafts
    /// list hides by thread, so each needs one).
    static func draftsMissingThread(suppressed: Set<String>,
                                    threadByDraft: [String: String]) -> Set<String> {
        suppressed.filter { threadByDraft[$0] == nil }
    }

    /// Thread entries left over from drafts that are no longer suppressed.
    static func staleThreadEntries(suppressed: Set<String>,
                                   threadByDraft: [String: String]) -> Set<String> {
        Set(threadByDraft.keys).subtracting(suppressed)
    }
}
