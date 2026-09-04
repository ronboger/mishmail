import Foundation

/// Whether an incoming `mailto:` is a duplicate delivery of the one already
/// on screen.
///
/// macOS can hand a single external open to more than one scene, and an app
/// can fire the same link twice. Both arrive as identical payloads within a
/// moment of each other, so the second must not queue another compose card.
///
/// The rule is deliberately narrow: a delivery is dropped only while the very
/// card it opened is still up. A link re-clicked after that card was
/// dismissed — or while an unrelated draft is open — is a fresh request and
/// must go through, or the handoff is silently lost.
enum MailtoDedupe {

    /// State kept about the last `mailto:` that opened a compose card.
    struct Record: Equatable {
        var mail: DefaultMailClient.Mailto
        var at: Date
        /// `ComposeRequest.id` of the card it opened. Nil while the link is
        /// queued behind a draft the user is still typing in.
        var requestId: UUID?
    }

    /// How long after a delivery an identical one counts as the same event.
    static let window: TimeInterval = 2

    /// True when `incoming` should be ignored.
    /// - Parameter activeRequestId: `composeRequest?.id`, or nil when no card
    ///   is open.
    static func shouldDrop(_ incoming: DefaultMailClient.Mailto,
                           last: Record?,
                           activeRequestId: UUID?,
                           now: Date,
                           window: TimeInterval = window) -> Bool {
        guard let last, last.mail == incoming else { return false }
        guard now.timeIntervalSince(last.at) < window else { return false }
        // Only the card this link opened suppresses a repeat. Opening is
        // synchronous, so a nil id means the link is queued behind someone
        // else's draft — a repeat would just re-queue the same handoff and
        // show the notice twice.
        guard let openId = last.requestId else { return true }
        return activeRequestId == openId
    }
}
