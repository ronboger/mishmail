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

    /// Identifies the compose card currently on screen, if any.
    struct ActiveCard: Equatable {
        var id: UUID
        /// A minimized card is replaceable, so it does not suppress a repeat:
        /// dropping one would make the click appear to do nothing.
        var isMinimized: Bool
    }

    /// True when an identical payload arrived inside the window.
    ///
    /// A negative interval means the clock stepped backwards; that is not a
    /// repeat, or a queued link would be dropped until the clock caught up.
    static func isRepeat<Payload: Equatable>(
        _ incoming: Payload, last: (payload: Payload, at: Date)?, now: Date,
        window: TimeInterval = window) -> Bool {
        guard let last, last.payload == incoming else { return false }
        let elapsed = now.timeIntervalSince(last.at)
        return elapsed >= 0 && elapsed < window
    }

    /// True when a `mailto:` should be ignored.
    ///
    /// The rule is deliberately narrow: a delivery is dropped only while the
    /// very card it opened is on screen. A link re-clicked after that card was
    /// dismissed — or while an unrelated draft is open — is a fresh request
    /// and must go through, or the handoff is silently lost.
    ///
    /// - Parameter activeCard: the compose card on screen, or nil when none
    ///   is open.
    static func shouldDropMailto(_ incoming: DefaultMailClient.Mailto,
                                 last: MailtoRecord?,
                                 activeCard: ActiveCard?,
                                 now: Date,
                                 window: TimeInterval = window) -> Bool {
        guard let last,
              isRepeat(incoming, last: (last.mail, last.at), now: now, window: window)
        else { return false }
        // Nothing on screen, or a minimized card: the repeat has a visible
        // card to open, so let it through rather than making the click a
        // no-op. This covers a queued link too — minimizing the draft that
        // blocked it makes it openable.
        guard let activeCard, !activeCard.isMinimized else { return false }
        // Opening is synchronous, so a nil id means the link is queued behind
        // someone else's draft — a repeat would just re-queue the same handoff
        // and show the notice twice.
        guard let openId = last.requestId else { return true }
        return activeCard.id == openId
    }
}
