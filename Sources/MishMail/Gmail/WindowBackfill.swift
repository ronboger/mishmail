import Foundation

/// Decisions for the sync-window backfill ("Last 90 days", "Everything").
///
/// One pass downloads at most a capped number of messages, so a large
/// mailbox cannot hold the sync runner for hours. A window bigger than the
/// cap is finished over several passes: the listing is recorded as finished
/// only when it reached its last page, and until then every pass lists the
/// window again. Ids already cached are skipped without a download and do
/// not count against the cap, so each pass continues where the last stopped.
enum WindowBackfill {
    /// UserDefaults key holding the window (in days) whose listing reached
    /// its last page. Unset while a backfill is still in progress. Separate
    /// from `backfill.window.<id>`, which records the window the local mail
    /// was last pruned to and reads 0 ("Everything") when unset.
    static func listedKey(accountId: String) -> String {
        "backfill.windowListed.\(accountId)"
    }

    enum Outcome: Equatable {
        /// Every message in the window is listed: record it.
        case complete
        /// The pass stopped at the cap: the next pass lists again.
        case continueNextPass
    }

    static func outcome(listingComplete: Bool) -> Outcome {
        listingComplete ? .complete : .continueNextPass
    }

    /// Whether a pass must list the window: the setting changed
    /// (`storedWindow`), or no listing for `days` has reached its last page.
    static func needsListing(storedWindow: Int, listedWindow: Int?, days: Int) -> Bool {
        storedWindow != days || listedWindow != days
    }

    /// Progress of one capped `messages.list` loop.
    struct ListingCap {
        let limit: Int
        /// True: every listed id counts (search, starred — the cap bounds
        /// the listing itself). False: only ids that needed a download
        /// count (the window backfill).
        let countsCachedIds: Bool
        private(set) var counted = 0

        init(limit: Int, countsCachedIds: Bool) {
            self.limit = limit
            self.countsCachedIds = countsCachedIds
        }

        /// Page size for the next list call. When listed ids count, never
        /// more than what is left, so a page cannot list past the cap.
        var pageSize: Int {
            countsCachedIds
                ? SyncEngine.listPageSize(listed: counted, limit: limit)
                : GmailClient.maxListPageSize
        }

        mutating func record(listed: Int, missing: Int) {
            counted += countsCachedIds ? listed : missing
        }

        var reached: Bool { counted >= limit }
    }
}
