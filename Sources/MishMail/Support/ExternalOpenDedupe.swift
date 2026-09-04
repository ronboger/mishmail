import Foundation

/// Whether an incoming external open (`mailto:` or `mishmail://thread/…`) is
/// a duplicate delivery of one just handled.
///
/// macOS can hand a single external open to more than one scene, and an app
/// can fire the same link twice. Both arrive as identical payloads within a
/// moment of each other, so the second must not open a second compose card or
/// repeat a "not available" notice.
enum ExternalOpenDedupe {

    /// How long after a delivery an identical one counts as the same event.
    static let window: TimeInterval = 2

    /// State kept about the last `mailto:` that opened a compose card.
    struct MailtoRecord: Equatable {
        var mail: DefaultMailClient.Mailto
        var at: Date
        /// `ComposeRequest.id` of the card it opened. Nil while the link is
        /// queued behind a draft the user is still typing in.
        var requestId: UUID?
    }

    /// True when an identical payload arrived inside the window.
    static func isRepeat<Payload: Equatable>(
        _ incoming: Payload, last: (payload: Payload, at: Date)?, now: Date,
        window: TimeInterval = window) -> Bool {
        guard let last, last.payload == incoming else { return false }
        return now.timeIntervalSince(last.at) < window
    }

    /// True when a `mailto:` should be ignored.
    ///
    /// The rule is deliberately narrow: a delivery is dropped only while the
    /// very card it opened is on screen. A link re-clicked after that card was
    /// dismissed — or while an unrelated draft is open — is a fresh request
    /// and must go through, or the handoff is silently lost.
    ///
    /// - Parameter activeRequestId: `composeRequest?.id` for a card the user
    ///   can see, nil when none is open or the card is minimized. A minimized
    ///   card is replaceable, so a repeat is allowed to open a visible one
    ///   rather than appearing to do nothing.
    static func shouldDropMailto(_ incoming: DefaultMailClient.Mailto,
                                 last: MailtoRecord?,
                                 activeRequestId: UUID?,
                                 now: Date,
                                 window: TimeInterval = window) -> Bool {
        guard let last,
              isRepeat(incoming, last: (last.mail, last.at), now: now, window: window)
        else { return false }
        // Opening is synchronous, so a nil id means the link is queued behind
        // someone else's draft — a repeat would just re-queue the same handoff
        // and show the notice twice.
        guard let openId = last.requestId else { return true }
        return activeRequestId == openId
    }
}
