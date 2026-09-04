import XCTest

final class MailtoDedupeTests: XCTestCase {

    private let link = DefaultMailClient.parseMailto("mailto:abe@example.com?subject=Hi")!
    private let other = DefaultMailClient.parseMailto("mailto:someone@else.com")!
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(_ mail: DefaultMailClient.Mailto, at: Date,
                        requestId: UUID?) -> MailtoDedupe.Record {
        .init(mail: mail, at: at, requestId: requestId)
    }

    func testFirstDeliveryIsNeverDropped() {
        XCTAssertFalse(MailtoDedupe.shouldDrop(
            link, last: nil, activeRequestId: nil, now: t0))
    }

    /// The case this exists for: one open reaches two scenes, so the same
    /// payload arrives twice while the card it opened is still up.
    func testDropsRepeatWhileItsOwnCardIsOpen() {
        let id = UUID()
        XCTAssertTrue(MailtoDedupe.shouldDrop(
            link, last: record(link, at: t0, requestId: id),
            activeRequestId: id, now: t0.addingTimeInterval(0.2)))
    }

    /// Re-clicking after dismissing the card is a fresh request, not a
    /// duplicate — dropping it would lose the handoff silently.
    func testAllowsReclickAfterCardClosed() {
        XCTAssertFalse(MailtoDedupe.shouldDrop(
            link, last: record(link, at: t0, requestId: UUID()),
            activeRequestId: nil, now: t0.addingTimeInterval(0.5)))
    }

    /// An unrelated draft being open says nothing about this link.
    func testAllowsRepeatWhenADifferentCardIsOpen() {
        XCTAssertFalse(MailtoDedupe.shouldDrop(
            link, last: record(link, at: t0, requestId: UUID()),
            activeRequestId: UUID(), now: t0.addingTimeInterval(0.5)))
    }

    /// Queued behind a draft (no card of its own yet): a repeat would only
    /// re-queue the same handoff and show the notice twice.
    func testDropsRepeatWhileQueued() {
        XCTAssertTrue(MailtoDedupe.shouldDrop(
            link, last: record(link, at: t0, requestId: nil),
            activeRequestId: UUID(), now: t0.addingTimeInterval(0.2)))
    }

    func testAllowsSameLinkAfterWindowElapses() {
        let id = UUID()
        XCTAssertFalse(MailtoDedupe.shouldDrop(
            link, last: record(link, at: t0, requestId: id),
            activeRequestId: id, now: t0.addingTimeInterval(MailtoDedupe.window + 0.1)))
    }

    func testAllowsADifferentLink() {
        let id = UUID()
        XCTAssertFalse(MailtoDedupe.shouldDrop(
            other, last: record(link, at: t0, requestId: id),
            activeRequestId: id, now: t0.addingTimeInterval(0.2)))
    }

    /// Same recipient but a different subject is a different message.
    func testPayloadComparisonCoversAllFields() {
        let withSubject = DefaultMailClient.parseMailto("mailto:a@x.com?subject=One")!
        let withOther = DefaultMailClient.parseMailto("mailto:a@x.com?subject=Two")!
        let id = UUID()
        XCTAssertFalse(MailtoDedupe.shouldDrop(
            withOther, last: record(withSubject, at: t0, requestId: id),
            activeRequestId: id, now: t0.addingTimeInterval(0.2)))
    }
}
