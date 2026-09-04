import XCTest

final class ExternalOpenDedupeTests: XCTestCase {

    private let link = DefaultMailClient.parseMailto("mailto:abe@example.com?subject=Hi")!
    private let other = DefaultMailClient.parseMailto("mailto:someone@else.com")!
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(_ mail: DefaultMailClient.Mailto, at: Date,
                        requestId: UUID?) -> ExternalOpenDedupe.MailtoRecord {
        .init(mail: mail, at: at, requestId: requestId)
    }

    private func card(_ id: UUID, minimized: Bool = false)
    -> ExternalOpenDedupe.ActiveCard {
        .init(id: id, isMinimized: minimized)
    }

    func testFirstDeliveryIsNeverDropped() {
        XCTAssertFalse(ExternalOpenDedupe.shouldDropMailto(
            link, last: nil, activeCard: nil, now: t0))
    }

    /// The case this exists for: one open reaches two scenes, so the same
    /// payload arrives twice while the card it opened is still up.
    func testDropsRepeatWhileItsOwnCardIsOpen() {
        let id = UUID()
        XCTAssertTrue(ExternalOpenDedupe.shouldDropMailto(
            link, last: record(link, at: t0, requestId: id),
            activeCard: card(id), now: t0.addingTimeInterval(0.2)))
    }

    /// Re-clicking after dismissing the card is a fresh request, not a
    /// duplicate — dropping it would lose the handoff silently.
    func testAllowsReclickAfterCardClosed() {
        XCTAssertFalse(ExternalOpenDedupe.shouldDropMailto(
            link, last: record(link, at: t0, requestId: UUID()),
            activeCard: nil, now: t0.addingTimeInterval(0.5)))
    }

    /// A minimized card is replaceable, so a repeat opens a visible one
    /// instead of appearing to do nothing. Same card id as the record —
    /// only `isMinimized` lets it through.
    func testAllowsRepeatWhenItsOwnCardIsMinimized() {
        let id = UUID()
        XCTAssertFalse(ExternalOpenDedupe.shouldDropMailto(
            link, last: record(link, at: t0, requestId: id),
            activeCard: card(id, minimized: true),
            now: t0.addingTimeInterval(0.2)))
    }

    /// An unrelated draft being open says nothing about this link.
    func testAllowsRepeatWhenADifferentCardIsOpen() {
        XCTAssertFalse(ExternalOpenDedupe.shouldDropMailto(
            link, last: record(link, at: t0, requestId: UUID()),
            activeCard: card(UUID()), now: t0.addingTimeInterval(0.5)))
    }

    /// Queued behind a draft (no card of its own yet): a repeat would only
    /// re-queue the same handoff and show the notice twice.
    func testDropsRepeatWhileQueued() {
        XCTAssertTrue(ExternalOpenDedupe.shouldDropMailto(
            link, last: record(link, at: t0, requestId: nil),
            activeCard: card(UUID()), now: t0.addingTimeInterval(0.2)))
    }

    /// Minimizing the draft that queued a link makes the link openable, so a
    /// repeat must not be swallowed.
    func testAllowsQueuedRepeatWhenTheBlockingDraftIsMinimized() {
        XCTAssertFalse(ExternalOpenDedupe.shouldDropMailto(
            link, last: record(link, at: t0, requestId: nil),
            activeCard: card(UUID(), minimized: true),
            now: t0.addingTimeInterval(0.2)))
    }

    func testAllowsSameLinkAfterWindowElapses() {
        let id = UUID()
        XCTAssertFalse(ExternalOpenDedupe.shouldDropMailto(
            link, last: record(link, at: t0, requestId: id),
            activeCard: card(id),
            now: t0.addingTimeInterval(ExternalOpenDedupe.window + 0.1)))
    }

    func testAllowsADifferentLink() {
        let id = UUID()
        XCTAssertFalse(ExternalOpenDedupe.shouldDropMailto(
            other, last: record(link, at: t0, requestId: id),
            activeCard: card(id), now: t0.addingTimeInterval(0.2)))
    }

    /// Same recipient but a different subject is a different message.
    func testPayloadComparisonCoversAllFields() {
        let withSubject = DefaultMailClient.parseMailto("mailto:a@x.com?subject=One")!
        let withOther = DefaultMailClient.parseMailto("mailto:a@x.com?subject=Two")!
        let id = UUID()
        XCTAssertFalse(ExternalOpenDedupe.shouldDropMailto(
            withOther, last: record(withSubject, at: t0, requestId: id),
            activeCard: card(id), now: t0.addingTimeInterval(0.2)))
    }

    /// A clock step backwards must not read as "just delivered", or a queued
    /// link would be dropped until the clock caught up.
    func testBackwardsClockIsNotARepeat() {
        XCTAssertFalse(ExternalOpenDedupe.shouldDropMailto(
            link, last: record(link, at: t0, requestId: nil),
            activeCard: card(UUID()), now: t0.addingTimeInterval(-60)))
        let target = MishMailDeepLinks.ThreadTarget(token: "abc", accountEmail: nil)
        XCTAssertFalse(ExternalOpenDedupe.isRepeat(
            target, last: (target, t0), now: t0.addingTimeInterval(-60)))
    }

    // MARK: - isRepeat (thread deep links)

    func testIsRepeatDropsIdenticalTargetInsideWindow() {
        let target = MishMailDeepLinks.ThreadTarget(token: "abc", accountEmail: "me@x.com")
        XCTAssertTrue(ExternalOpenDedupe.isRepeat(
            target, last: (target, t0), now: t0.addingTimeInterval(0.3)))
        XCTAssertFalse(ExternalOpenDedupe.isRepeat(
            target, last: (target, t0),
            now: t0.addingTimeInterval(ExternalOpenDedupe.window + 0.1)))
    }

    func testIsRepeatDistinguishesTargets() {
        let a = MishMailDeepLinks.ThreadTarget(token: "abc", accountEmail: "me@x.com")
        let b = MishMailDeepLinks.ThreadTarget(token: "abc", accountEmail: "other@x.com")
        XCTAssertFalse(ExternalOpenDedupe.isRepeat(
            b, last: (a, t0), now: t0.addingTimeInterval(0.3)))
        XCTAssertFalse(ExternalOpenDedupe.isRepeat(
            a, last: nil, now: t0))
    }
}
