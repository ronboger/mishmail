import Foundation

/// Decisions the app makes when Gmail is unreachable (plane, tunnel, captive
/// portal). Pure so the rules are unit-tested; `MailStore` owns the queues.
///
/// The rule of thumb: nothing the user did while offline is lost, and nothing
/// the user did *not* do (a background poll) earns a sticky error banner.
enum OfflinePolicy {
    /// A failed Gmail call that should be parked and replayed later rather
    /// than reported. Anything else (4xx, auth, decode) is a real failure.
    static func shouldDefer(_ error: Error) -> Bool {
        TransientNetworkError.isTransient(error)
    }

    /// Whether a sync failure earns the sticky error banner with a Sync button.
    /// Connectivity failures never do: the interactive path shows a passing
    /// notice instead, and the background path stays silent. Repeating
    /// "won't sync" while the user is on a plane tells them nothing new.
    static func surfacesSyncFailure(_ error: Error) -> Bool {
        !TransientNetworkError.isTransient(error)
    }

    /// One-line status for the sync control while offline.
    static func offlineStatusLabel(queuedSends: Int, localDrafts: Int,
                                   pendingEdits: Int) -> String {
        var parts: [String] = []
        if queuedSends > 0 {
            parts.append(queuedSends == 1 ? "1 message to send" : "\(queuedSends) messages to send")
        }
        if localDrafts > 0 {
            parts.append(localDrafts == 1 ? "1 draft to upload" : "\(localDrafts) drafts to upload")
        }
        if pendingEdits > 0 {
            parts.append(pendingEdits == 1 ? "1 change to sync" : "\(pendingEdits) changes to sync")
        }
        guard !parts.isEmpty else { return "Offline" }
        return "Offline · " + parts.joined(separator: ", ")
    }

    /// Toast for a user-initiated sync that found no network.
    static let offlineSyncNotice = "You're offline — showing cached mail"

    /// Toast when Send could not reach Gmail.
    static let queuedSendNotice = "You're offline — will send when you're back online"

    /// Toast when a draft was kept locally instead of uploaded.
    static let localDraftNotice = "Saved offline — uploads to Drafts when you're back online"

    /// A scheduled-send row whose time has passed is waiting on the network,
    /// not on the clock. Used by the Scheduled list to label such rows.
    static func isWaitingForConnection(sendAt: Date, now: Date = Date()) -> Bool {
        sendAt <= now
    }

    static let waitingForConnectionLabel = "Waiting for connection"
}
